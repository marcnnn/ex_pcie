/* ex_pcie NIF: vfio-pci access (BARs, DMA, MSI/MSI-X via eventfd + enif_select),
 * plus generic file mmap (sysfs resourceN). No kernel driver needed. */
#define _GNU_SOURCE
#include <erl_nif.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__has_include)
#if __has_include(<linux/vfio.h>)
#include <linux/vfio.h>
#define HAVE_VFIO 1
#endif
#endif
#ifndef HAVE_VFIO
#define HAVE_VFIO 0
#endif

#define PAGE_SZ 4096ULL
#define HUGE_SZ (2ULL * 1024 * 1024)
#define IOVA_BASE 0x100000000ULL

static ErlNifResourceType *DEV_T, *BAR_T, *DMA_T, *EVT_T;
static ERL_NIF_TERM A_ok, A_error, A_true, A_false, A_undefined, A_irq, A_test_no_iommu, A_msi, A_msix,
    A_unsupported, A_oob, A_unaligned, A_closed;

/* ---- resources ---- */
typedef struct {
  int container, group, device;
  uint64_t next_iova;
  ErlNifMutex *mu;
} dev_t_;

typedef struct {
  volatile uint8_t *base;
  size_t size;
  dev_t_ *dev; /* kept reference or NULL */
} bar_t;

typedef struct {
  ErlNifMutex *mu;
  void *va;
  size_t size, map_size;
  uint64_t iova;
  dev_t_ *dev; /* NULL: not iommu mapped */
  int mapped; /* iommu mapped */
  int live;
} dma_t;

typedef struct {
  int fd;
  ErlNifMutex *mu;
  int subscribed;
  ErlNifPid pid;
  ErlNifEnv *tag_env;
  ERL_NIF_TERM tag;
  int vector;
} evt_t;

static uint64_t test_iova_next = IOVA_BASE;
static ErlNifMutex *test_mu;

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *s) {
  ERL_NIF_TERM t;
  if (enif_make_existing_atom(env, s, &t, ERL_NIF_LATIN1)) return t;
  return enif_make_atom(env, s);
}

static ERL_NIF_TERM errno_atom(ErlNifEnv *env, int e) {
  switch (e) {
  case ENOENT: return atom(env, "enoent");
  case EACCES: return atom(env, "eacces");
  case EPERM: return atom(env, "eperm");
  case EBUSY: return atom(env, "ebusy");
  case EINVAL: return atom(env, "einval");
  case ENOMEM: return atom(env, "enomem");
  case ENODEV: return atom(env, "enodev");
  case EFAULT: return atom(env, "efault");
  case ENXIO: return atom(env, "enxio");
  case EIO: return atom(env, "eio");
  case EAGAIN: return atom(env, "eagain");
  case EEXIST: return atom(env, "eexist");
  case ENOTTY: return atom(env, "enotty");
  case EMFILE: return atom(env, "emfile");
  case ENFILE: return atom(env, "enfile");
  case ENOSPC: return atom(env, "enospc");
  case ENOTDIR: return atom(env, "enotdir");
  case ENAMETOOLONG: return atom(env, "enametoolong");
  default: {
    char b[32];
    snprintf(b, sizeof b, "errno_%d", e);
    return atom(env, b);
  }
  }
}

static ERL_NIF_TERM err(ErlNifEnv *env, ERL_NIF_TERM reason) { return enif_make_tuple2(env, A_error, reason); }
static ERL_NIF_TERM err_errno(ErlNifEnv *env, int e) { return err(env, errno_atom(env, e)); }
static ERL_NIF_TERM ok2(ErlNifEnv *env, ERL_NIF_TERM t) { return enif_make_tuple2(env, A_ok, t); }

static int get_size(ErlNifEnv *env, ERL_NIF_TERM t, size_t *out) {
  ErlNifUInt64 v;
  if (!enif_get_uint64(env, t, &v) || v > (uint64_t)SSIZE_MAX) return 0;
  *out = (size_t)v;
  return 1;
}

static int get_string(ErlNifEnv *env, ERL_NIF_TERM t, char *buf, size_t cap) {
  ErlNifBinary b;
  if (!enif_inspect_binary(env, t, &b) || b.size == 0 || b.size >= cap || memchr(b.data, 0, b.size)) return 0;
  memcpy(buf, b.data, b.size);
  buf[b.size] = 0;
  return 1;
}

/* ---- destructors ---- */
static void dev_dtor(ErlNifEnv *env, void *obj) {
  (void)env;
  dev_t_ *d = obj;
  if (d->device >= 0) close(d->device);
  if (d->group >= 0) close(d->group);
  if (d->container >= 0) close(d->container);
  if (d->mu) enif_mutex_destroy(d->mu);
}

static void bar_dtor(ErlNifEnv *env, void *obj) {
  (void)env;
  bar_t *b = obj;
  if (b->base) munmap((void *)b->base, b->size);
  if (b->dev) enif_release_resource(b->dev);
}

#if HAVE_VFIO
static void dma_release_locked(dma_t *m) {
  if (!m->live) return;
  if (m->mapped && m->dev) {
    struct vfio_iommu_type1_dma_unmap u = {.argsz = sizeof u, .flags = 0, .iova = m->iova, .size = m->map_size};
    ioctl(m->dev->container, VFIO_IOMMU_UNMAP_DMA, &u);
  }
  munmap(m->va, m->map_size);
  m->live = 0;
  m->mapped = 0;
}
#else
static void dma_release_locked(dma_t *m) {
  if (!m->live) return;
  munmap(m->va, m->map_size);
  m->live = 0;
}
#endif

static void dma_dtor(ErlNifEnv *env, void *obj) {
  (void)env;
  dma_t *m = obj;
  dma_release_locked(m);
  if (m->dev) enif_release_resource(m->dev);
  if (m->mu) enif_mutex_destroy(m->mu);
}

static void evt_dtor(ErlNifEnv *env, void *obj) {
  (void)env;
  evt_t *e = obj;
  if (e->fd >= 0) close(e->fd);
  if (e->tag_env) enif_free_env(e->tag_env);
  if (e->mu) enif_mutex_destroy(e->mu);
}

static void evt_stop(ErlNifEnv *env, void *obj, ErlNifEvent event, int is_direct_call) {
  (void)env;
  (void)is_direct_call;
  evt_t *e = obj;
  if (e->fd == event && e->fd >= 0) {
    close(e->fd);
    e->fd = -1;
  }
}

/* ---- capabilities ---- */
static ERL_NIF_TERM nif_capabilities(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  ERL_NIF_TERM m = enif_make_new_map(env);
  enif_make_map_put(env, m, atom(env, "version"), enif_make_int(env, 1), &m);
  enif_make_map_put(env, m, atom(env, "vfio"), HAVE_VFIO ? A_true : A_false, &m);
  enif_make_map_put(env, m, atom(env, "mmap_file"), A_true, &m);
  enif_make_map_put(env, m, atom(env, "eventfd"), A_true, &m);
  enif_make_map_put(env, m, atom(env, "dma"), A_true, &m);
  enif_make_map_put(env, m, atom(env, "hugepages"), A_true, &m);
  return m;
}

/* ---- mmap of arbitrary file (sysfs resourceN) ---- */
static ERL_NIF_TERM make_bar(ErlNifEnv *env, void *base, size_t size, dev_t_ *dev) {
  bar_t *b = enif_alloc_resource(BAR_T, sizeof *b);
  b->base = base;
  b->size = size;
  b->dev = dev;
  if (dev) enif_keep_resource(dev);
  ERL_NIF_TERM t = enif_make_resource(env, b);
  enif_release_resource(b);
  return ok2(env, t);
}

static ERL_NIF_TERM nif_mmap_file(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  char path[PATH_MAX];
  size_t size;
  if (!get_string(env, argv[0], path, sizeof path) || !get_size(env, argv[1], &size)) return enif_make_badarg(env);
  int fd = open(path, O_RDWR | O_SYNC | O_CLOEXEC);
  if (fd < 0) return err_errno(env, errno);
  if (size == 0) {
    struct stat st;
    if (fstat(fd, &st) < 0) {
      int e = errno;
      close(fd);
      return err_errno(env, e);
    }
    size = (size_t)st.st_size;
  }
  if (size == 0) {
    close(fd);
    return err(env, atom(env, "einval"));
  }
  void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  int e = errno;
  close(fd);
  if (p == MAP_FAILED) return err_errno(env, e);
  return make_bar(env, p, size, NULL);
}

/* ---- BAR access ---- */
static ERL_NIF_TERM nif_bar_size(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  bar_t *b;
  if (!enif_get_resource(env, argv[0], BAR_T, (void **)&b)) return enif_make_badarg(env);
  return enif_make_uint64(env, b->size);
}

static int check_range(bar_t *b, size_t off, size_t len, ERL_NIF_TERM *errt, ErlNifEnv *env) {
  if ((off | len) & 3) {
    *errt = err(env, A_unaligned);
    return 0;
  }
  if (off > b->size || len > b->size - off) {
    *errt = err(env, A_oob);
    return 0;
  }
  return 1;
}

static ERL_NIF_TERM nif_bar_read32(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  bar_t *b;
  size_t off;
  ERL_NIF_TERM e;
  if (!enif_get_resource(env, argv[0], BAR_T, (void **)&b) || !get_size(env, argv[1], &off)) return enif_make_badarg(env);
  if (!check_range(b, off, 4, &e, env)) return e;
  uint32_t v = *(volatile uint32_t *)(b->base + off);
  return ok2(env, enif_make_uint(env, v));
}

static ERL_NIF_TERM nif_bar_write32(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  bar_t *b;
  size_t off;
  unsigned int v;
  ERL_NIF_TERM e;
  if (!enif_get_resource(env, argv[0], BAR_T, (void **)&b) || !get_size(env, argv[1], &off) ||
      !enif_get_uint(env, argv[2], &v))
    return enif_make_badarg(env);
  if (!check_range(b, off, 4, &e, env)) return e;
  *(volatile uint32_t *)(b->base + off) = v;
  return A_ok;
}

static ERL_NIF_TERM nif_bar_read(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  bar_t *b;
  size_t off, len;
  ERL_NIF_TERM e, bin;
  if (!enif_get_resource(env, argv[0], BAR_T, (void **)&b) || !get_size(env, argv[1], &off) ||
      !get_size(env, argv[2], &len))
    return enif_make_badarg(env);
  if (!check_range(b, off, len, &e, env)) return e;
  unsigned char *out = enif_make_new_binary(env, len, &bin);
  for (size_t i = 0; i < len; i += 4) {
    uint32_t v = *(volatile uint32_t *)(b->base + off + i);
    memcpy(out + i, &v, 4);
  }
  return ok2(env, bin);
}

static ERL_NIF_TERM nif_bar_write(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  bar_t *b;
  size_t off;
  ErlNifBinary bin;
  ERL_NIF_TERM e;
  if (!enif_get_resource(env, argv[0], BAR_T, (void **)&b) || !get_size(env, argv[1], &off) ||
      !enif_inspect_binary(env, argv[2], &bin))
    return enif_make_badarg(env);
  if (!check_range(b, off, bin.size, &e, env)) return e;
  for (size_t i = 0; i < bin.size; i += 4) {
    uint32_t v;
    memcpy(&v, bin.data + i, 4);
    *(volatile uint32_t *)(b->base + off + i) = v;
  }
  return A_ok;
}

/* ---- DMA buffers ---- */
static ERL_NIF_TERM nif_dma_alloc(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  dev_t_ *dev = NULL;
  size_t size;
  int huge;
  if (enif_is_identical(argv[0], A_test_no_iommu)) {
  } else if (!enif_get_resource(env, argv[0], DEV_T, (void **)&dev))
    return enif_make_badarg(env);
  if (!get_size(env, argv[1], &size) || size == 0 || size > ((size_t)1 << 40)) return enif_make_badarg(env);
  if (enif_is_identical(argv[2], A_true)) huge = 1;
  else if (enif_is_identical(argv[2], A_false)) huge = 0;
  else return enif_make_badarg(env);

  uint64_t align = huge ? HUGE_SZ : PAGE_SZ;
  size_t map_size = (size + align - 1) / align * align;
  int flags = MAP_PRIVATE | MAP_ANONYMOUS | (huge ? MAP_HUGETLB : 0);
  void *va = mmap(NULL, map_size, PROT_READ | PROT_WRITE, flags, -1, 0);
  if (va == MAP_FAILED) return err_errno(env, errno);
  mlock(va, map_size); /* best effort; vfio pins on map anyway */

  uint64_t iova;
  ErlNifMutex *mu = dev ? dev->mu : test_mu;
  uint64_t *next = dev ? &dev->next_iova : &test_iova_next;
  enif_mutex_lock(mu);
  iova = (*next + align - 1) / align * align;
  *next = iova + map_size;
  enif_mutex_unlock(mu);

  int mapped = 0;
#if HAVE_VFIO
  if (dev) {
    struct vfio_iommu_type1_dma_map m = {.argsz = sizeof m,
                                         .flags = VFIO_DMA_MAP_FLAG_READ | VFIO_DMA_MAP_FLAG_WRITE,
                                         .vaddr = (uintptr_t)va,
                                         .iova = iova,
                                         .size = map_size};
    if (ioctl(dev->container, VFIO_IOMMU_MAP_DMA, &m) < 0) {
      int e = errno;
      munmap(va, map_size);
      return err_errno(env, e);
    }
    mapped = 1;
  }
#else
  if (dev) {
    munmap(va, map_size);
    return err(env, A_unsupported);
  }
#endif

  dma_t *m = enif_alloc_resource(DMA_T, sizeof *m);
  memset(m, 0, sizeof *m);
  m->mu = enif_mutex_create("ex_pcie_dma");
  m->va = va;
  m->size = size;
  m->map_size = map_size;
  m->iova = iova;
  m->dev = dev;
  m->mapped = mapped;
  m->live = 1;
  if (dev) enif_keep_resource(dev);
  ERL_NIF_TERM t = enif_make_resource(env, m);
  enif_release_resource(m);
  return enif_make_tuple3(env, A_ok, t, enif_make_uint64(env, iova));
}

static ERL_NIF_TERM nif_dma_free(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  dma_t *m;
  if (!enif_get_resource(env, argv[0], DMA_T, (void **)&m)) return enif_make_badarg(env);
  enif_mutex_lock(m->mu);
  dma_release_locked(m);
  enif_mutex_unlock(m->mu);
  return A_ok;
}

static ERL_NIF_TERM nif_dma_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  dma_t *m;
  if (!enif_get_resource(env, argv[0], DMA_T, (void **)&m)) return enif_make_badarg(env);
  return enif_make_tuple2(env, enif_make_uint64(env, m->iova), enif_make_uint64(env, m->size));
}

static ERL_NIF_TERM nif_dma_read(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  dma_t *m;
  size_t off, len;
  ERL_NIF_TERM bin;
  if (!enif_get_resource(env, argv[0], DMA_T, (void **)&m) || !get_size(env, argv[1], &off) ||
      !get_size(env, argv[2], &len))
    return enif_make_badarg(env);
  if (off > m->size || len > m->size - off) return err(env, A_oob);
  enif_mutex_lock(m->mu);
  if (!m->live) {
    enif_mutex_unlock(m->mu);
    return err(env, A_closed);
  }
  unsigned char *out = enif_make_new_binary(env, len, &bin);
  memcpy(out, (unsigned char *)m->va + off, len);
  enif_mutex_unlock(m->mu);
  return ok2(env, bin);
}

static ERL_NIF_TERM nif_dma_write(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  dma_t *m;
  size_t off;
  ErlNifBinary bin;
  if (!enif_get_resource(env, argv[0], DMA_T, (void **)&m) || !get_size(env, argv[1], &off) ||
      !enif_inspect_binary(env, argv[2], &bin))
    return enif_make_badarg(env);
  if (off > m->size || bin.size > m->size - off) return err(env, A_oob);
  enif_mutex_lock(m->mu);
  if (!m->live) {
    enif_mutex_unlock(m->mu);
    return err(env, A_closed);
  }
  memcpy((unsigned char *)m->va + off, bin.data, bin.size);
  enif_mutex_unlock(m->mu);
  return A_ok;
}

/* ---- eventfd + enif_select ---- */
static ERL_NIF_TERM nif_eventfd_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  int vector;
  if (!enif_get_int(env, argv[0], &vector)) return enif_make_badarg(env);
  int fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  if (fd < 0) return err_errno(env, errno);
  evt_t *e = enif_alloc_resource(EVT_T, sizeof *e);
  memset(e, 0, sizeof *e);
  e->fd = fd;
  e->vector = vector;
  e->mu = enif_mutex_create("ex_pcie_evt");
  ERL_NIF_TERM t = enif_make_resource(env, e);
  enif_release_resource(e);
  return ok2(env, t);
}

static ERL_NIF_TERM nif_eventfd_signal(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  evt_t *e;
  if (!enif_get_resource(env, argv[0], EVT_T, (void **)&e)) return enif_make_badarg(env);
  enif_mutex_lock(e->mu);
  uint64_t one = 1;
  int fd = e->fd;
  ssize_t r = fd >= 0 ? write(fd, &one, sizeof one) : -1;
  int en = fd >= 0 ? errno : EBADF;
  enif_mutex_unlock(e->mu);
  if (r != (ssize_t)sizeof one) return en == EBADF ? err(env, A_closed) : err_errno(env, en);
  return A_ok;
}

/* must hold e->mu */
static int evt_arm_locked(ErlNifEnv *env, evt_t *e) {
  if (!e->subscribed || e->fd < 0) return 0;
  ERL_NIF_TERM msg = enif_make_tuple3(env, A_irq, enif_make_copy(env, e->tag), enif_make_int(env, e->vector));
  int r = enif_select_x(env, e->fd, ERL_NIF_SELECT_READ | ERL_NIF_SELECT_CUSTOM_MSG, e, &e->pid, msg, NULL);
  return r < 0 ? -1 : 0;
}

static ERL_NIF_TERM nif_irq_subscribe(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  evt_t *e;
  ErlNifPid pid;
  if (!enif_get_resource(env, argv[0], EVT_T, (void **)&e) || !enif_get_local_pid(env, argv[1], &pid))
    return enif_make_badarg(env);
  enif_mutex_lock(e->mu);
  if (e->fd < 0) {
    enif_mutex_unlock(e->mu);
    return err(env, A_closed);
  }
  if (e->subscribed) enif_select(env, e->fd, ERL_NIF_SELECT_CANCEL, e, NULL, A_undefined);
  if (e->tag_env) enif_free_env(e->tag_env);
  e->tag_env = enif_alloc_env();
  e->tag = enif_make_copy(e->tag_env, argv[2]);
  e->pid = pid;
  e->subscribed = 1;
  int r = evt_arm_locked(env, e);
  enif_mutex_unlock(e->mu);
  return r < 0 ? err(env, atom(env, "select_failed")) : A_ok;
}

static ERL_NIF_TERM nif_irq_unsubscribe(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  evt_t *e;
  if (!enif_get_resource(env, argv[0], EVT_T, (void **)&e)) return enif_make_badarg(env);
  enif_mutex_lock(e->mu);
  if (e->subscribed && e->fd >= 0) enif_select(env, e->fd, ERL_NIF_SELECT_CANCEL, e, NULL, A_undefined);
  e->subscribed = 0;
  enif_mutex_unlock(e->mu);
  return A_ok;
}

/* Read (and clear) the counter, then re-arm the select. Returns the count. */
static ERL_NIF_TERM nif_irq_ack(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  evt_t *e;
  if (!enif_get_resource(env, argv[0], EVT_T, (void **)&e)) return enif_make_badarg(env);
  enif_mutex_lock(e->mu);
  if (e->fd < 0) {
    enif_mutex_unlock(e->mu);
    return err(env, A_closed);
  }
  uint64_t cnt = 0;
  if (read(e->fd, &cnt, sizeof cnt) != (ssize_t)sizeof cnt) cnt = 0;
  int r = evt_arm_locked(env, e);
  enif_mutex_unlock(e->mu);
  if (r < 0) return err(env, atom(env, "select_failed"));
  return ok2(env, enif_make_uint64(env, cnt));
}

static ERL_NIF_TERM nif_eventfd_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  evt_t *e;
  if (!enif_get_resource(env, argv[0], EVT_T, (void **)&e)) return enif_make_badarg(env);
  enif_mutex_lock(e->mu);
  e->subscribed = 0;
  int fd = e->fd;
  if (fd >= 0) {
    /* the stop callback closes the fd (directly if nothing is selected) */
    enif_select(env, fd, ERL_NIF_SELECT_STOP, e, NULL, A_undefined);
  }
  enif_mutex_unlock(e->mu);
  return A_ok;
}

/* ---- VFIO ---- */
#if HAVE_VFIO
static int valid_bdf(const char *s) {
  size_t n = strlen(s);
  if (n < 7 || n > 16) return 0;
  for (size_t i = 0; i < n; i++)
    if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f') || (s[i] >= 'A' && s[i] <= 'F') || s[i] == ':' ||
          s[i] == '.'))
      return 0;
  return 1;
}

static ERL_NIF_TERM nif_vfio_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  char bdf[32], link[PATH_MAX], path[PATH_MAX];
  if (!get_string(env, argv[0], bdf, sizeof bdf) || !valid_bdf(bdf)) return enif_make_badarg(env);

  snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/iommu_group", bdf);
  ssize_t n = readlink(path, link, sizeof link - 1);
  if (n < 0) return err_errno(env, errno);
  link[n] = 0;
  const char *g = strrchr(link, '/');
  g = g ? g + 1 : link;
  if (!*g || strspn(g, "0123456789") != strlen(g)) return err(env, atom(env, "bad_iommu_group"));

  dev_t_ *d = enif_alloc_resource(DEV_T, sizeof *d);
  d->container = d->group = d->device = -1;
  d->next_iova = IOVA_BASE;
  d->mu = enif_mutex_create("ex_pcie_dev");
  int e = 0;
  ERL_NIF_TERM reason = 0;

  d->container = open("/dev/vfio/vfio", O_RDWR | O_CLOEXEC);
  if (d->container < 0) { e = errno; goto fail; }
  if (ioctl(d->container, VFIO_GET_API_VERSION) != VFIO_API_VERSION) { reason = atom(env, "vfio_api_version"); goto fail; }

  snprintf(path, sizeof path, "/dev/vfio/%s", g);
  d->group = open(path, O_RDWR | O_CLOEXEC);
  if (d->group < 0) { e = errno; goto fail; }
  struct vfio_group_status st = {.argsz = sizeof st};
  if (ioctl(d->group, VFIO_GROUP_GET_STATUS, &st) < 0) { e = errno; goto fail; }
  if (!(st.flags & VFIO_GROUP_FLAGS_VIABLE)) { reason = atom(env, "group_not_viable"); goto fail; }
  if (ioctl(d->group, VFIO_GROUP_SET_CONTAINER, &d->container) < 0) { e = errno; goto fail; }
  if (ioctl(d->container, VFIO_SET_IOMMU, VFIO_TYPE1v2_IOMMU) < 0 &&
      ioctl(d->container, VFIO_SET_IOMMU, VFIO_TYPE1_IOMMU) < 0) { e = errno; goto fail; }
  d->device = ioctl(d->group, VFIO_GROUP_GET_DEVICE_FD, bdf);
  if (d->device < 0) { e = errno; goto fail; }

  ERL_NIF_TERM t = enif_make_resource(env, d);
  enif_release_resource(d);
  return ok2(env, t);
fail:
  enif_release_resource(d); /* dtor closes whatever was opened */
  return reason ? err(env, reason) : err_errno(env, e);
}

static int bar_region(int idx) { return VFIO_PCI_BAR0_REGION_INDEX + idx; }

static ERL_NIF_TERM nif_vfio_region_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  dev_t_ *d;
  int bar;
  if (!enif_get_resource(env, argv[0], DEV_T, (void **)&d) || !enif_get_int(env, argv[1], &bar) || bar < 0 || bar > 5)
    return enif_make_badarg(env);
  struct vfio_region_info ri = {.argsz = sizeof ri, .index = bar_region(bar)};
  if (ioctl(d->device, VFIO_DEVICE_GET_REGION_INFO, &ri) < 0) return err_errno(env, errno);
  return ok2(env, enif_make_tuple3(env, enif_make_uint64(env, ri.size), enif_make_uint(env, ri.flags),
                                   enif_make_uint64(env, ri.offset)));
}

static ERL_NIF_TERM nif_vfio_map_bar(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  dev_t_ *d;
  int bar;
  if (!enif_get_resource(env, argv[0], DEV_T, (void **)&d) || !enif_get_int(env, argv[1], &bar) || bar < 0 || bar > 5)
    return enif_make_badarg(env);
  struct vfio_region_info ri = {.argsz = sizeof ri, .index = bar_region(bar)};
  if (ioctl(d->device, VFIO_DEVICE_GET_REGION_INFO, &ri) < 0) return err_errno(env, errno);
  if (ri.size == 0) return err(env, atom(env, "enodev"));
  if (!(ri.flags & VFIO_REGION_INFO_FLAG_MMAP)) return err(env, A_unsupported);
  void *p = mmap(NULL, ri.size, PROT_READ | PROT_WRITE, MAP_SHARED, d->device, ri.offset);
  if (p == MAP_FAILED) return err_errno(env, errno);
  return make_bar(env, p, ri.size, d);
}

static ERL_NIF_TERM nif_vfio_irq_count(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  dev_t_ *d;
  if (!enif_get_resource(env, argv[0], DEV_T, (void **)&d)) return enif_make_badarg(env);
  int idx = enif_is_identical(argv[1], A_msix) ? VFIO_PCI_MSIX_IRQ_INDEX
            : enif_is_identical(argv[1], A_msi) ? VFIO_PCI_MSI_IRQ_INDEX : -1;
  if (idx < 0) return enif_make_badarg(env);
  struct vfio_irq_info ii = {.argsz = sizeof ii, .index = idx};
  if (ioctl(d->device, VFIO_DEVICE_GET_IRQ_INFO, &ii) < 0) return err_errno(env, errno);
  return ok2(env, enif_make_uint(env, ii.count));
}

/* vfio_irq_enable(dev, :msi | :msix, [evt]) ; vector i triggers the i-th eventfd */
static ERL_NIF_TERM nif_vfio_irq_enable(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  dev_t_ *d;
  if (!enif_get_resource(env, argv[0], DEV_T, (void **)&d)) return enif_make_badarg(env);
  int idx = enif_is_identical(argv[1], A_msix) ? VFIO_PCI_MSIX_IRQ_INDEX
            : enif_is_identical(argv[1], A_msi) ? VFIO_PCI_MSI_IRQ_INDEX : -1;
  unsigned n;
  if (idx < 0 || !enif_get_list_length(env, argv[2], &n) || n == 0 || n > 2048) return enif_make_badarg(env);
  size_t sz = sizeof(struct vfio_irq_set) + n * sizeof(int32_t);
  struct vfio_irq_set *s = calloc(1, sz);
  if (!s) return err(env, atom(env, "enomem"));
  int32_t *fds = (int32_t *)s->data;
  ERL_NIF_TERM l = argv[2], h;
  for (unsigned i = 0; i < n; i++) {
    evt_t *e;
    enif_get_list_cell(env, l, &h, &l);
    if (!enif_get_resource(env, h, EVT_T, (void **)&e) || e->fd < 0) {
      free(s);
      return enif_make_badarg(env);
    }
    fds[i] = e->fd;
  }
  s->argsz = (uint32_t)sz;
  s->flags = VFIO_IRQ_SET_DATA_EVENTFD | VFIO_IRQ_SET_ACTION_TRIGGER;
  s->index = idx;
  s->start = 0;
  s->count = n;
  int r = ioctl(d->device, VFIO_DEVICE_SET_IRQS, s);
  int e = errno;
  free(s);
  return r < 0 ? err_errno(env, e) : A_ok;
}

static ERL_NIF_TERM nif_vfio_irq_disable(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  dev_t_ *d;
  if (!enif_get_resource(env, argv[0], DEV_T, (void **)&d)) return enif_make_badarg(env);
  int idx = enif_is_identical(argv[1], A_msix) ? VFIO_PCI_MSIX_IRQ_INDEX
            : enif_is_identical(argv[1], A_msi) ? VFIO_PCI_MSI_IRQ_INDEX : -1;
  if (idx < 0) return enif_make_badarg(env);
  struct vfio_irq_set s = {.argsz = sizeof s,
                           .flags = VFIO_IRQ_SET_DATA_NONE | VFIO_IRQ_SET_ACTION_TRIGGER,
                           .index = idx,
                           .start = 0,
                           .count = 0};
  if (ioctl(d->device, VFIO_DEVICE_SET_IRQS, &s) < 0) return err_errno(env, errno);
  return A_ok;
}
#else
#define UNSUPPORTED(name) \
  static ERL_NIF_TERM name(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) { \
    (void)argc; (void)argv; return err(env, A_unsupported); }
UNSUPPORTED(nif_vfio_open)
UNSUPPORTED(nif_vfio_region_info)
UNSUPPORTED(nif_vfio_map_bar)
UNSUPPORTED(nif_vfio_irq_count)
UNSUPPORTED(nif_vfio_irq_enable)
UNSUPPORTED(nif_vfio_irq_disable)
#endif

/* ---- load ---- */
static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
  (void)priv;
  (void)info;
  ErlNifResourceFlags fl = ERL_NIF_RT_CREATE;
  ErlNifResourceTypeInit i_dev = {.dtor = dev_dtor}, i_bar = {.dtor = bar_dtor}, i_dma = {.dtor = dma_dtor},
                         i_evt = {.dtor = evt_dtor, .stop = evt_stop};
  DEV_T = enif_open_resource_type_x(env, "ex_pcie_dev", &i_dev, fl, NULL);
  BAR_T = enif_open_resource_type_x(env, "ex_pcie_bar", &i_bar, fl, NULL);
  DMA_T = enif_open_resource_type_x(env, "ex_pcie_dma", &i_dma, fl, NULL);
  EVT_T = enif_open_resource_type_x(env, "ex_pcie_evt", &i_evt, fl, NULL);
  if (!DEV_T || !BAR_T || !DMA_T || !EVT_T) return 1;
  test_mu = enif_mutex_create("ex_pcie_test_iova");
  A_ok = atom(env, "ok");
  A_error = atom(env, "error");
  A_true = atom(env, "true");
  A_false = atom(env, "false");
  A_undefined = atom(env, "undefined");
  A_irq = atom(env, "ex_pcie_irq");
  A_test_no_iommu = atom(env, "test_no_iommu");
  A_msi = atom(env, "msi");
  A_msix = atom(env, "msix");
  A_unsupported = atom(env, "unsupported");
  A_oob = atom(env, "out_of_bounds");
  A_unaligned = atom(env, "unaligned");
  A_closed = atom(env, "closed");
  return 0;
}

static ErlNifFunc funcs[] = {
    {"capabilities", 0, nif_capabilities, 0},
    {"mmap_file", 2, nif_mmap_file, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"bar_size", 1, nif_bar_size, 0},
    {"bar_read32", 2, nif_bar_read32, 0},
    {"bar_write32", 3, nif_bar_write32, 0},
    {"bar_read", 3, nif_bar_read, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"bar_write", 3, nif_bar_write, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"dma_alloc", 3, nif_dma_alloc, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"dma_free", 1, nif_dma_free, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"dma_info", 1, nif_dma_info, 0},
    {"dma_read", 3, nif_dma_read, 0},
    {"dma_write", 3, nif_dma_write, 0},
    {"eventfd_new", 1, nif_eventfd_new, 0},
    {"eventfd_signal", 1, nif_eventfd_signal, 0},
    {"eventfd_close", 1, nif_eventfd_close, 0},
    {"irq_subscribe", 3, nif_irq_subscribe, 0},
    {"irq_unsubscribe", 1, nif_irq_unsubscribe, 0},
    {"irq_ack", 1, nif_irq_ack, 0},
    {"vfio_open", 1, nif_vfio_open, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"vfio_region_info", 2, nif_vfio_region_info, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"vfio_map_bar", 2, nif_vfio_map_bar, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"vfio_irq_count", 2, nif_vfio_irq_count, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"vfio_irq_enable", 3, nif_vfio_irq_enable, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"vfio_irq_disable", 2, nif_vfio_irq_disable, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(Elixir.ExPcie.Nif, funcs, load, NULL, NULL, NULL)
