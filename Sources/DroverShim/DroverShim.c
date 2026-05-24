#include "DroverShim.h"

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

typedef enum {
    PROXY_DIRECT,
    PROXY_HTTP,
    PROXY_SOCKS5
} proxy_mode_t;

typedef struct {
    int fd;
    int type;
    bool has_sent;
    bool fake_http_response;
} socket_state_t;

static int (*system_socket)(int, int, int);
static ssize_t (*system_send)(int, const void *, size_t, int);
static ssize_t (*system_recv)(int, void *, size_t, int);
static ssize_t (*system_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
static ssize_t (*system_sendmsg)(int, const struct msghdr *, int);

static pthread_once_t resolve_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t sockets_lock = PTHREAD_MUTEX_INITIALIZER;
static socket_state_t *sockets;
static size_t socket_count;
static size_t socket_capacity;

static proxy_mode_t proxy_mode = PROXY_DIRECT;
static char proxy_login[512];
static char proxy_password[512];
static char packet_path[PATH_MAX];

static void resolve_system_calls(void) {
    system_socket = dlsym(RTLD_NEXT, "socket");
    system_send = dlsym(RTLD_NEXT, "send");
    system_recv = dlsym(RTLD_NEXT, "recv");
    system_sendto = dlsym(RTLD_NEXT, "sendto");
    system_sendmsg = dlsym(RTLD_NEXT, "sendmsg");
}

static void ensure_system_calls(void) {
    pthread_once(&resolve_once, resolve_system_calls);
}

static char *trim(char *value) {
    while (*value == ' ' || *value == '\t' || *value == '\r' || *value == '\n') {
        value++;
    }
    char *end = value + strlen(value);
    while (end > value && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' || end[-1] == '\n')) {
        *--end = '\0';
    }
    return value;
}

static void parse_proxy(char *value) {
    proxy_mode = PROXY_DIRECT;
    proxy_login[0] = '\0';
    proxy_password[0] = '\0';

    value = trim(value);
    if (*value == '\0') {
        return;
    }

    char *scheme_end = strstr(value, "://");
    if (scheme_end == NULL) {
        return;
    }
    *scheme_end = '\0';
    if (strcasecmp(value, "http") == 0 || strcasecmp(value, "https") == 0) {
        proxy_mode = PROXY_HTTP;
    } else if (strcasecmp(value, "socks5") == 0) {
        proxy_mode = PROXY_SOCKS5;
    } else {
        return;
    }

    char *authority = scheme_end + 3;
    char *at = strchr(authority, '@');
    if (at != NULL && proxy_mode == PROXY_HTTP) {
        *at = '\0';
        char *colon = strchr(authority, ':');
        if (colon != NULL) {
            *colon = '\0';
            snprintf(proxy_login, sizeof(proxy_login), "%s", authority);
            snprintf(proxy_password, sizeof(proxy_password), "%s", colon + 1);
        }
    }
}

__attribute__((constructor))
static void initialize_drover(void) {
    const char *directory = getenv("DROVER_CONFIG_DIR");
    if (directory == NULL || *directory == '\0') {
        return;
    }

    char configuration_path[PATH_MAX];
    snprintf(configuration_path, sizeof(configuration_path), "%s/drover.ini", directory);
    snprintf(packet_path, sizeof(packet_path), "%s/drover-packet.bin", directory);

    FILE *configuration = fopen(configuration_path, "r");
    if (configuration == NULL) {
        return;
    }

    char line[2048];
    while (fgets(line, sizeof(line), configuration) != NULL) {
        char *entry = trim(line);
        if (strncasecmp(entry, "proxy", 5) != 0) {
            continue;
        }
        char *equals = strchr(entry, '=');
        if (equals != NULL) {
            parse_proxy(equals + 1);
            break;
        }
    }
    fclose(configuration);
}

static ssize_t find_socket_unlocked(int fd) {
    for (size_t index = 0; index < socket_count; index++) {
        if (sockets[index].fd == fd) {
            return (ssize_t)index;
        }
    }
    return -1;
}

static void track_socket(int fd, int type) {
    if (fd < 0) {
        return;
    }

    pthread_mutex_lock(&sockets_lock);
    ssize_t existing = find_socket_unlocked(fd);
    if (existing >= 0) {
        sockets[existing] = (socket_state_t){ .fd = fd, .type = type };
        pthread_mutex_unlock(&sockets_lock);
        return;
    }

    if (socket_count == socket_capacity) {
        size_t expanded = socket_capacity == 0 ? 32 : socket_capacity * 2;
        socket_state_t *replacement = realloc(sockets, expanded * sizeof(*replacement));
        if (replacement == NULL) {
            pthread_mutex_unlock(&sockets_lock);
            return;
        }
        sockets = replacement;
        socket_capacity = expanded;
    }
    sockets[socket_count++] = (socket_state_t){ .fd = fd, .type = type };
    pthread_mutex_unlock(&sockets_lock);
}

static bool mark_first_send(int fd, int *type) {
    bool first = false;
    *type = 0;
    pthread_mutex_lock(&sockets_lock);
    ssize_t existing = find_socket_unlocked(fd);
    if (existing >= 0) {
        *type = sockets[existing].type;
        if (!sockets[existing].has_sent) {
            sockets[existing].has_sent = true;
            first = true;
        }
    }
    pthread_mutex_unlock(&sockets_lock);
    return first;
}

static void set_fake_http_response(int fd) {
    pthread_mutex_lock(&sockets_lock);
    ssize_t existing = find_socket_unlocked(fd);
    if (existing >= 0) {
        sockets[existing].fake_http_response = true;
    }
    pthread_mutex_unlock(&sockets_lock);
}

static bool reset_fake_http_response(int fd) {
    bool result = false;
    pthread_mutex_lock(&sockets_lock);
    ssize_t existing = find_socket_unlocked(fd);
    if (existing >= 0 && sockets[existing].fake_http_response) {
        sockets[existing].fake_http_response = false;
        result = true;
    }
    pthread_mutex_unlock(&sockets_lock);
    return result;
}

static const unsigned char *find_bytes(
    const unsigned char *buffer,
    size_t length,
    const char *needle,
    size_t needle_length
) {
    if (needle_length == 0 || length < needle_length) {
        return NULL;
    }
    for (size_t index = 0; index <= length - needle_length; index++) {
        if (memcmp(buffer + index, needle, needle_length) == 0) {
            return buffer + index;
        }
    }
    return NULL;
}

static char *base64_credentials(void) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t login_length = strlen(proxy_login);
    size_t password_length = strlen(proxy_password);
    size_t raw_length = login_length + 1 + password_length;
    unsigned char *raw = malloc(raw_length);
    if (raw == NULL) {
        return NULL;
    }
    memcpy(raw, proxy_login, login_length);
    raw[login_length] = ':';
    memcpy(raw + login_length + 1, proxy_password, password_length);

    size_t encoded_length = ((raw_length + 2) / 3) * 4;
    char *encoded = malloc(encoded_length + 1);
    if (encoded == NULL) {
        free(raw);
        return NULL;
    }

    size_t output = 0;
    for (size_t input = 0; input < raw_length; input += 3) {
        uint32_t group = (uint32_t)raw[input] << 16;
        size_t remaining = raw_length - input;
        if (remaining > 1) group |= (uint32_t)raw[input + 1] << 8;
        if (remaining > 2) group |= raw[input + 2];
        encoded[output++] = alphabet[(group >> 18) & 0x3f];
        encoded[output++] = alphabet[(group >> 12) & 0x3f];
        encoded[output++] = remaining > 1 ? alphabet[(group >> 6) & 0x3f] : '=';
        encoded[output++] = remaining > 2 ? alphabet[group & 0x3f] : '=';
    }
    encoded[output] = '\0';
    free(raw);
    return encoded;
}

static unsigned char *request_with_http_authorization(const void *input, size_t length) {
    if (proxy_mode != PROXY_HTTP || proxy_login[0] == '\0' || proxy_password[0] == '\0') {
        return NULL;
    }

    const unsigned char *buffer = input;
    const char existing_header[] = "\r\nProxy-Authorization: ";
    if (find_bytes(buffer, length, existing_header, sizeof(existing_header) - 1) != NULL) {
        return NULL;
    }

    const char user_agent[] = "User-Agent:";
    const unsigned char *begin = find_bytes(buffer, length, user_agent, sizeof(user_agent) - 1);
    if (begin == NULL) {
        return NULL;
    }
    const unsigned char *end = find_bytes(
        begin,
        length - (size_t)(begin - buffer),
        "\r\n",
        2
    );
    if (end == NULL) {
        return NULL;
    }

    char *encoded = base64_credentials();
    if (encoded == NULL) {
        return NULL;
    }
    char authorization[1536];
    int authorization_length = snprintf(
        authorization,
        sizeof(authorization),
        "Proxy-Authorization: Basic %s",
        encoded
    );
    free(encoded);
    if (authorization_length < 0 || (size_t)authorization_length >= sizeof(authorization)) {
        return NULL;
    }

    size_t replaced_length = (size_t)(end - begin);
    if (replaced_length < (size_t)authorization_length + 6) {
        return NULL;
    }

    unsigned char *replacement = malloc(length);
    if (replacement == NULL) {
        return NULL;
    }
    memcpy(replacement, buffer, length);
    size_t begin_offset = (size_t)(begin - buffer);
    memcpy(replacement + begin_offset, authorization, (size_t)authorization_length);

    size_t filler_length = replaced_length - (size_t)authorization_length;
    memcpy(replacement + begin_offset + authorization_length, "\r\nX: ", 5);
    memset(replacement + begin_offset + authorization_length + 5, 'X', filler_length - 5);
    return replacement;
}

static bool send_all(int fd, const unsigned char *bytes, size_t length, int flags) {
    while (length > 0) {
        ssize_t sent = system_send(fd, bytes, length, flags);
        if (sent <= 0) {
            return false;
        }
        bytes += sent;
        length -= (size_t)sent;
    }
    return true;
}

static bool receive_exact(int fd, unsigned char *bytes, size_t length) {
    while (length > 0) {
        struct pollfd descriptor = { .fd = fd, .events = POLLIN };
        if (poll(&descriptor, 1, 10000) <= 0) {
            return false;
        }
        ssize_t received = system_recv(fd, bytes, length, 0);
        if (received <= 0) {
            return false;
        }
        bytes += received;
        length -= (size_t)received;
    }
    return true;
}

static bool convert_http_connect_to_socks5(int fd, const void *input, size_t length, int flags) {
    if (proxy_mode != PROXY_SOCKS5 || length < 10 || memcmp(input, "CONNECT ", 8) != 0) {
        return false;
    }

    const unsigned char *request = input;
    const unsigned char *host_begin = request + 8;
    const unsigned char *colon = memchr(host_begin, ':', length - 8);
    if (colon == NULL || colon == host_begin || (size_t)(colon - host_begin) > 255) {
        return false;
    }
    const unsigned char *port_begin = colon + 1;
    char port_string[8] = {0};
    size_t port_length = 0;
    while ((size_t)(port_begin - request) + port_length < length &&
           port_length < sizeof(port_string) - 1 &&
           port_begin[port_length] >= '0' && port_begin[port_length] <= '9') {
        port_string[port_length] = (char)port_begin[port_length];
        port_length++;
    }
    long port = strtol(port_string, NULL, 10);
    if (port_length == 0 || port < 1 || port > 65535) {
        return false;
    }

    unsigned char greeting[] = {0x05, 0x01, 0x00};
    unsigned char greeting_reply[2];
    if (!send_all(fd, greeting, sizeof(greeting), flags) ||
        !receive_exact(fd, greeting_reply, sizeof(greeting_reply)) ||
        greeting_reply[0] != 0x05 || greeting_reply[1] != 0x00) {
        return false;
    }

    size_t host_length = (size_t)(colon - host_begin);
    unsigned char socks_request[4 + 1 + 255 + 2];
    size_t socks_length = 0;
    socks_request[socks_length++] = 0x05;
    socks_request[socks_length++] = 0x01;
    socks_request[socks_length++] = 0x00;
    socks_request[socks_length++] = 0x03;
    socks_request[socks_length++] = (unsigned char)host_length;
    memcpy(socks_request + socks_length, host_begin, host_length);
    socks_length += host_length;
    socks_request[socks_length++] = (unsigned char)((port >> 8) & 0xff);
    socks_request[socks_length++] = (unsigned char)(port & 0xff);

    if (!send_all(fd, socks_request, socks_length, flags)) {
        return false;
    }
    set_fake_http_response(fd);
    return true;
}

static ssize_t substitute_socks_response(int fd, void *buffer, size_t length, ssize_t received) {
    if (received <= 0 || !reset_fake_http_response(fd)) {
        return received;
    }
    static const char response[] = "HTTP/1.1 200 Connection Established\r\n\r\n";
    if (received >= 3 &&
        ((unsigned char *)buffer)[0] == 0x05 &&
        ((unsigned char *)buffer)[1] == 0x00 &&
        ((unsigned char *)buffer)[2] == 0x00 &&
        length >= sizeof(response) - 1) {
        memcpy(buffer, response, sizeof(response) - 1);
        return (ssize_t)(sizeof(response) - 1);
    }
    return received;
}

static void inject_udp_preamble(int fd, const struct sockaddr *destination, socklen_t destination_length) {
    if (packet_path[0] != '\0') {
        FILE *packet = fopen(packet_path, "rb");
        if (packet != NULL) {
            if (fseek(packet, 0, SEEK_END) == 0) {
                long packet_length = ftell(packet);
                if (packet_length > 0 && fseek(packet, 0, SEEK_SET) == 0) {
                    unsigned char *bytes = malloc((size_t)packet_length);
                    if (bytes != NULL) {
                        if (fread(bytes, 1, (size_t)packet_length, packet) == (size_t)packet_length) {
                            system_sendto(fd, bytes, (size_t)packet_length, 0, destination, destination_length);
                        }
                        free(bytes);
                    }
                }
            }
            fclose(packet);
        }
    }

    const unsigned char zero = 0;
    const unsigned char one = 1;
    system_sendto(fd, &zero, 1, 0, destination, destination_length);
    system_sendto(fd, &one, 1, 0, destination, destination_length);
    usleep(50000);
}

int drover_socket(int domain, int type, int protocol) {
    ensure_system_calls();
    int fd = system_socket(domain, type, protocol);
    if ((type & SOCK_STREAM) == SOCK_STREAM || (type & SOCK_DGRAM) == SOCK_DGRAM) {
        track_socket(fd, type & 0xffff);
    }
    return fd;
}

ssize_t drover_send(int fd, const void *buffer, size_t length, int flags) {
    ensure_system_calls();
    int type;
    if (mark_first_send(fd, &type) && (type & SOCK_STREAM) == SOCK_STREAM) {
        if (convert_http_connect_to_socks5(fd, buffer, length, flags)) {
            return (ssize_t)length;
        }
        unsigned char *replacement = request_with_http_authorization(buffer, length);
        if (replacement != NULL) {
            ssize_t result = system_send(fd, replacement, length, flags);
            free(replacement);
            return result;
        }
    }
    return system_send(fd, buffer, length, flags);
}

ssize_t drover_recv(int fd, void *buffer, size_t length, int flags) {
    ensure_system_calls();
    return substitute_socks_response(fd, buffer, length, system_recv(fd, buffer, length, flags));
}

ssize_t drover_sendto(
    int fd,
    const void *buffer,
    size_t length,
    int flags,
    const struct sockaddr *destination,
    socklen_t destination_length
) {
    ensure_system_calls();
    int type;
    if (mark_first_send(fd, &type) && (type & SOCK_DGRAM) == SOCK_DGRAM && length == 74) {
        inject_udp_preamble(fd, destination, destination_length);
    }
    return system_sendto(fd, buffer, length, flags, destination, destination_length);
}

ssize_t drover_sendmsg(int fd, const struct msghdr *message, int flags) {
    ensure_system_calls();
    int type;
    size_t length = 0;
    for (int index = 0; index < message->msg_iovlen; index++) {
        length += message->msg_iov[index].iov_len;
    }
    if (mark_first_send(fd, &type) && (type & SOCK_DGRAM) == SOCK_DGRAM &&
        length == 74 && message->msg_name != NULL) {
        inject_udp_preamble(fd, message->msg_name, message->msg_namelen);
    }
    return system_sendmsg(fd, message, flags);
}

#define DYLD_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    interpose_##replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&replacement, (const void *)(uintptr_t)&replacee \
    }

DYLD_INTERPOSE(drover_socket, socket);
DYLD_INTERPOSE(drover_send, send);
DYLD_INTERPOSE(drover_recv, recv);
DYLD_INTERPOSE(drover_sendto, sendto);
DYLD_INTERPOSE(drover_sendmsg, sendmsg);
