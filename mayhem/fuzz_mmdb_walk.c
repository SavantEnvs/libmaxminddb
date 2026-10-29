#ifndef _POSIX_C_SOURCE
    #define _POSIX_C_SOURCE 200809L
#endif

#include "maxminddb.h"
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define kMinInputLength 2
#define kMaxInputLength (256 * 1024)
#define kMaxNodes 2048

extern int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

static void dump_entry(MMDB_entry_s *entry) {
    MMDB_entry_data_list_s *list = NULL;
    if (MMDB_get_entry_data_list(entry, &list) == MMDB_SUCCESS && list) {
        char *buf = NULL;
        size_t len = 0;
        FILE *sink = open_memstream(&buf, &len);
        if (sink) {
            MMDB_dump_entry_data_list(sink, list, 0);
            fclose(sink);
            free(buf);
        }
    }
    MMDB_free_entry_data_list(list);
}

static void lookup_string(const MMDB_s *mmdb, const char *ip) {
    int gai_error, mmdb_error;
    MMDB_lookup_result_s r = MMDB_lookup_string(mmdb, ip, &gai_error, &mmdb_error);
    if (gai_error != 0 || mmdb_error != MMDB_SUCCESS || !r.found_entry) {
        return;
    }
    dump_entry(&r.entry);

    MMDB_entry_data_s d;
    MMDB_get_value(&r.entry, &d, "country", "iso_code", NULL);
    MMDB_get_value(&r.entry, &d, "location", "latitude", NULL);
    const char *path[] = {"subdivisions", "0", "names", "en", NULL};
    MMDB_aget_value(&r.entry, &d, path);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < kMinInputLength || size > kMaxInputLength) {
        return -1;
    }

    const char *tmpdir = getenv("TMPDIR");
    char filename[4096];
    snprintf(filename, sizeof filename, "%s/mmdbwalk.XXXXXX",
             tmpdir && *tmpdir ? tmpdir : "/tmp");
    int const fd = mkstemp(filename);
    if (fd == -1) {
        abort();
    }
    size_t written = 0;
    while (written < size) {
        ssize_t n = write(fd, data + written, size - written);
        if (n <= 0) {
            close(fd);
            unlink(filename);
            abort();
        }
        written += (size_t)n;
    }
    close(fd);

    MMDB_s mmdb;
    int status = MMDB_open(filename, MMDB_MODE_MMAP, &mmdb);
    unlink(filename);
    if (status != MMDB_SUCCESS) {
        return -1;
    }

    static const char *const ips[] = {"1.1.1.1",    "81.2.69.160", "2.125.160.216",
                                      "::1",        "2001:db8::1", "::ffff:1.2.3.4",
                                      "2a02:2c00::", "255.255.255.255"};
    for (size_t i = 0; i < sizeof ips / sizeof ips[0]; i++) {
        lookup_string(&mmdb, ips[i]);
    }

    struct sockaddr_in sa4;
    memset(&sa4, 0, sizeof sa4);
    sa4.sin_family = AF_INET;
    sa4.sin_addr.s_addr = htonl(0x01010101u ^ (uint32_t)size);
    int mmdb_error;
    MMDB_lookup_result_s r =
        MMDB_lookup_sockaddr(&mmdb, (struct sockaddr *)&sa4, &mmdb_error);
    if (mmdb_error == MMDB_SUCCESS && r.found_entry) {
        dump_entry(&r.entry);
    }

    uint32_t nodes = mmdb.metadata.node_count < kMaxNodes ? mmdb.metadata.node_count
                                                         : kMaxNodes;
    for (uint32_t n = 0; n < nodes; n++) {
        MMDB_search_node_s node;
        if (MMDB_read_node(&mmdb, n, &node) != MMDB_SUCCESS) {
            break;
        }
        if (node.left_record_type == MMDB_RECORD_TYPE_DATA) {
            dump_entry(&node.left_record_entry);
        }
        if (node.right_record_type == MMDB_RECORD_TYPE_DATA) {
            dump_entry(&node.right_record_entry);
        }
    }

    MMDB_entry_data_list_s *meta = NULL;
    if (MMDB_get_metadata_as_entry_data_list(&mmdb, &meta) == MMDB_SUCCESS) {
        MMDB_free_entry_data_list(meta);
    }
    (void)MMDB_lib_version();

    MMDB_close(&mmdb);
    return 0;
}
