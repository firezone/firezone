#ifndef FIREZONE_COMPLETION_H
#define FIREZONE_COMPLETION_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct CompletionSession FzCompletionSession;
typedef struct BufferLease FzCompletionBuffer;
typedef struct { uint8_t address[16]; uint16_t port; uint8_t family; uint32_t scope_id; } FzEndpoint;
typedef struct { const uint8_t *data; size_t len; } FzByteSlice;
typedef struct {
    uint64_t id, generation;
    uint32_t kind;
    FzCompletionBuffer *buffer;
    size_t packets, segment_size;
    FzEndpoint local, remote;
    uint8_t ecn;
} FzPacketOperation;

/* All session calls must be serialized. 0 = success, 1 = no operation,
 * 2 = session closed, -1 = error, -2 = panic (discard session).
 * UniFFI owns configuration, commands and typed events.
 * The driver_handle returned by connect_completion is cast to FzCompletionSession*.
 * Send operations must be submitted in order for each socket/TUN.
 * Borrowed receive storage stays immutable until its release callback.
 * Output storage stays valid until buffer_free, independently of complete.
 * Completion IDs must be acknowledged exactly once, including failed sends.
 * Buffer and string releases need no live session and may run on any thread. */
void fz_completion_free(FzCompletionSession *);
int32_t fz_completion_poll(FzCompletionSession *);
const char *fz_completion_error(const FzCompletionSession *);
int32_t fz_completion_receive_ready(FzCompletionSession *, bool network);
int32_t fz_completion_receive_network(FzCompletionSession *, uint64_t generation, const uint8_t *, size_t,
    FzEndpoint local, FzEndpoint remote, uint8_t ecn, void *context, void (*release)(void *));
int32_t fz_completion_receive_tun(FzCompletionSession *, uint64_t generation, const FzByteSlice *, size_t);
int32_t fz_completion_next_operation(FzCompletionSession *, FzPacketOperation *);
int32_t fz_completion_packet(const FzCompletionBuffer *, size_t index, FzByteSlice *);
void fz_completion_buffer_free(FzCompletionBuffer *);
int32_t fz_completion_complete(FzCompletionSession *, uint64_t id, int32_t status);
int32_t fz_completion_endpoint_parse(const char *, uint16_t port, FzEndpoint *);
#endif
