/*
 * smoke_guest_linux.c
 *
 * Linux x86-64 port of upstream `xtask/src/smoke_guest.m` against `reims_vgpu.h`.
 * Exercises the exact C API and guest MMIO / Root FIFO protocol used by QEMU's
 * `apple-gfx-pci` and macOS `AppleParavirtGPU`:
 *   1. Allocates guest RAM via `memfd_create` + `mmap(MAP_SHARED)`.
 *   2. Calls `rvg_device_create` with `RvgMemoryMap`, `RvgMemoryRangeFile` (memfd),
 *      and `RvgHostCallbacks` (`raise_interrupt`).
 *   3. Negotiates MMIO `R_VERSION = 245`, `R_ROOT_PAGE`, `R_BASE_PAGE`, `R_ENABLE = 1`.
 *   4. Submits `OP_NOP` (30), `OP_DEFINE_TASK2` (56), `OP_MAP_MEMORY2` (57),
 *      `OP_SET_OBJECT_LIST` (51), and `OP_EXEC_INDIRECT3` (67) with a `FillBuffer` (306)
 *      command that writes 32 bytes of `0xab` at offset `0x10` in shared guest RAM.
 *   5. Verifies the Vulkan backend executed the fill into guest RAM with zero faults.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "reims_vgpu.h"

// Guest RAM at GPA 0x40000000, 128 pages of 4 KiB (APV_PAGE_SIZE on x86_64).
#define PAGE 0x1000ull
#define RAM_BASE 0x40000000ull
#define RAM_PAGES 128ull
#define BP ((uint32_t)(RAM_BASE / PAGE))
#define ROOT_PAGE (BP + 1)
#define FIFO_PAGE (BP + 2)
#define FIFO_LENGTH ((uint32_t)PAGE)
#define FIFO_START 0x400u
#define RING (FIFO_LENGTH - FIFO_START)
#define TASK_ROOT (BP + 4)
#define TASK_TABLE (BP + 5)
#define TASK_DATA (BP + 16)
#define TASK_PAGES 16u
#define TASK_LEN ((uint64_t)TASK_PAGES * PAGE)
#define VA_CMD 0ull
#define VA_REC PAGE
#define VA_OL (2 * PAGE)
#define VA_BUF_PAGE 3u
#define FILL_AT 0x10ull
#define FILL_LEN 0x20ull
#define FILL_VALUE 0xab

// Registers (docs/testing.md 6.2).
#define R_ENABLE 0x1000
#define R_LENGTH 0x1004
#define R_WRITTEN 0x1008
#define R_READ 0x100c
#define R_START 0x1010
#define R_ROOT_PAGE 0x101c
#define R_FAULTED 0x102c
#define R_BASE_PAGE 0x1030
#define R_VERSION 0x1034
#define R_FAULT_OFFSET 0x103c

// Opcodes (docs/testing.md 6.8).
#define OP_NOP 30
#define OP_SET_OBJECT_LIST 51
#define OP_DEFINE_TASK2 56
#define OP_MAP_MEMORY2 57
#define OP_EXEC_INDIRECT3 67

static uint8_t *ram;
static atomic_uint interrupts;
static uint32_t written, stamp;
static RvgDevice *device;

static void raise_interrupt(void *ctx, uint32_t vector) {
    (void)ctx;
    (void)vector;
    atomic_fetch_add(&interrupts, 1);
}

static uint32_t mmio_read(uint64_t offset) {
    return rvg_device_mmio_read(device, offset);
}

static void mmio_write(uint64_t offset, uint32_t value) {
    rvg_device_mmio_write(device, offset, value);
}

static uint8_t *gpa(uint64_t address) {
    return ram + (address - RAM_BASE);
}

static uint64_t page(uint32_t p) {
    return (uint64_t)p * PAGE;
}

static void put(uint64_t address, const void *bytes, size_t length) {
    memcpy(gpa(address), bytes, length);
    atomic_thread_fence(memory_order_seq_cst);
}

static uint32_t get32(uint64_t address) {
    atomic_thread_fence(memory_order_seq_cst);
    return *(volatile uint32_t *)gpa(address);
}

static uint64_t get64(uint64_t address) {
    atomic_thread_fence(memory_order_seq_cst);
    return *(volatile uint64_t *)gpa(address);
}

typedef struct {
    uint8_t bytes[64];
    uint32_t length;
} Payload;

static void add(Payload *p, const void *bytes, uint32_t length) {
    memcpy(p->bytes + p->length, bytes, length);
    p->length += length;
}
static void add32(Payload *p, uint32_t v) { add(p, &v, 4); }
static void add64(Payload *p, uint64_t v) { add(p, &v, 8); }

static uint32_t push(uint16_t op, const Payload *payload) {
    stamp++;
    uint8_t c[80];
    uint32_t length = 12 + (payload ? payload->length : 0), zero = 0;
    memcpy(c, &op, 2);
    memcpy(c + 2, &zero, 2);
    memcpy(c + 4, &length, 4);
    memcpy(c + 8, &stamp, 4);
    if (payload)
        memcpy(c + 12, payload->bytes, payload->length);
    uint64_t ring = page(FIFO_PAGE) + FIFO_START;
    for (uint32_t i = 0; i < length; i++)
        put(ring + (written + i) % RING, &c[i], 1);
    written += length;
    mmio_write(R_WRITTEN, written);
    return stamp;
}

static const char *wait_stamp(uint32_t s) {
    for (int i = 0; i < 10000; i++) {
        if (get32(page(FIFO_PAGE)) >= s)
            return "ok";
        if (mmio_read(R_FAULTED) == 1)
            return "fault";
        usleep(1000);
    }
    return "timeout";
}

static const char *run(const char *key, uint16_t op, const Payload *payload) {
    const char *r = wait_stamp(push(op, payload));
    printf("%s: %s\n", key, r);
    if (strcmp(r, "ok"))
        printf("%s_fault_offset: 0x%x\n", key, mmio_read(R_FAULT_OFFSET));
    return r;
}

static int guest(void) {
    mmio_write(R_VERSION, 245);
    printf("version: %u\n", mmio_read(R_VERSION));
    mmio_write(R_ROOT_PAGE, ROOT_PAGE);
    printf("root_page: %s\n", mmio_read(R_ROOT_PAGE) == ROOT_PAGE ? "ok" : "lost");
    mmio_write(R_BASE_PAGE, FIFO_PAGE);
    mmio_write(R_LENGTH, FIFO_LENGTH);
    mmio_write(R_START, FIFO_START);
    mmio_write(R_ENABLE, 1);
    printf("fifo_enabled: %u\n", mmio_read(R_ENABLE));
    printf("fault_offset: 0x%x\n", mmio_read(R_FAULT_OFFSET));
    if (strcmp(run("nop", OP_NOP, NULL), "ok"))
        return 1;
    printf("read: %u\n", mmio_read(R_READ));
    for (int i = 0; i < 1000 && !atomic_load(&interrupts); i++)
        usleep(1000);
    printf("interrupt: %s\n", atomic_load(&interrupts) ? "raised" : "none");

    // Task 1's root (depth 1) and page table, every page writable.
    uint32_t root[10] = {TASK_TABLE, 1};
    put(page(TASK_ROOT), root, sizeof(root));
    for (uint32_t i = 0; i < TASK_PAGES; i++) {
        uint32_t pte = (TASK_DATA + i) | 1u << 31;
        put(page(TASK_TABLE) + 4 * i, &pte, 4);
    }

    uint64_t data = page(TASK_DATA);
    uint8_t rec[16] = {0};
    uint64_t rec_length = PAGE;
    uint32_t rec_page = VA_BUF_PAGE;
    memcpy(rec, &rec_length, 8);
    memcpy(rec + 8, &rec_page, 4);
    put(data + VA_REC, rec, sizeof(rec));

    Payload ol = {{0}, 0};
    add32(&ol, 0);
    add64(&ol, 0);
    add32(&ol, 1u | 16u << 8);
    add64(&ol, VA_REC);
    put(data + VA_OL, ol.bytes, ol.length);

    Payload seg = {{0}, 0};
    add32(&seg, 0x28);
    add32(&seg, 2);
    add32(&seg, 306);
    add32(&seg, 8 + 0x18);
    add32(&seg, 1);
    add64(&seg, FILL_AT);
    add64(&seg, FILL_LEN);
    add32(&seg, FILL_VALUE);
    put(data + VA_CMD, seg.bytes, seg.length);

    Payload define = {{0}, 0};
    add32(&define, 1u << 1);
    add64(&define, TASK_LEN);
    add32(&define, TASK_ROOT);
    const char *r = run("task_define", OP_DEFINE_TASK2, &define);
    printf("task_handshake: %s\n", !strcmp(r, "ok") ? "accepted" : "refused");
    if (strcmp(r, "ok"))
        return 1;
    printf("task_root_word: %s\n", get32(page(ROOT_PAGE) + 4) == TASK_ROOT ? "ok" : "unset");
    printf("task_length: %s\n", get64(page(TASK_ROOT) + 0x14) == TASK_LEN ? "ok" : "unset");

    Payload map = {{0}, 0};
    add32(&map, 1);
    add64(&map, 0);
    add64(&map, TASK_LEN);
    if (strcmp(run("task_map", OP_MAP_MEMORY2, &map), "ok"))
        return 1;

    Payload objects = {{0}, 0};
    add32(&objects, 1);
    add32(&objects, (uint32_t)(VA_OL / PAGE));
    add32(&objects, 24);
    if (strcmp(run("task_objects", OP_SET_OBJECT_LIST, &objects), "ok"))
        return 1;

    Payload exec = {{0}, 0};
    add32(&exec, 1);
    add32(&exec, 1);
    add32(&exec, 1);
    add32(&exec, 1);
    add32(&exec, 0);
    add64(&exec, VA_CMD);
    add64(&exec, 0x28);
    if (strcmp(run("task_exec", OP_EXEC_INDIRECT3, &exec), "ok"))
        return 1;

    uint64_t buf = data + page(VA_BUF_PAGE);
    int filled = 0;
    for (int i = 0; i < 10000 && !filled; i++) {
        atomic_thread_fence(memory_order_seq_cst);
        filled = 1;
        for (uint64_t k = 0; k < FILL_LEN; k++)
            filled &= gpa(buf + FILL_AT)[k] == FILL_VALUE;
        if (!filled)
            usleep(1000);
    }
    int outside = gpa(buf + FILL_AT - 1)[0] != 0 || gpa(buf + FILL_AT + FILL_LEN)[0] != 0;
    printf("task_fill: %s\n", !filled ? "missing" : outside ? "overran" : "ok");
    printf("faulted: %u\n", mmio_read(R_FAULTED));
    return (!filled || outside || mmio_read(R_FAULTED) != 0) ? 1 : 0;
}

int main(void) {
    printf("=== TAHOEBOOT REIMS VGPU GUEST WORKLOAD SMOKE TEST (x86_64 LINUX) ===\n");
    size_t ram_bytes = RAM_PAGES * PAGE;
    int fd = memfd_create("tahoeboot-smoke-ram", 0);
    if (fd < 0 || ftruncate(fd, (off_t)ram_bytes) != 0) {
        perror("memfd_create");
        return 1;
    }
    ram = mmap(NULL, ram_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ram == MAP_FAILED) {
        perror("mmap");
        return 1;
    }

    RvgMemoryRange range = {RAM_BASE, ram_bytes, ram};
    RvgMemoryMap map = {&range, 1};
    RvgMemoryRangeFile mfile = {.fd = fd, .flags = 0, .offset = 0};
    RvgHostCallbacks callbacks = {
        .struct_size = sizeof(callbacks),
        .raise_interrupt = raise_interrupt,
    };
    RvgDeviceConfig config = {
        .struct_size = sizeof(config),
        .display_port_count = 1,
        .process_isolation = false,
        .memory_map = &map,
        .callbacks = &callbacks,
        .memory_files = &mfile,
    };

    RvgStatus status = rvg_device_create(&config, &device);
    printf("device: %s (status=%u)\n", status == 0 ? "created" : rvg_status_message(status), status);
    int rc = 1;
    if (status == 0) {
        rc = guest();
        rvg_device_release(device);
    }
    munmap(ram, ram_bytes);
    close(fd);
    printf("done: %s\n", rc == 0 ? "ok" : "failed");
    fflush(stdout);
    return rc;
}
