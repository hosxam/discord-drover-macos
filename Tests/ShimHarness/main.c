#include <arpa/inet.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define FAIL(message) do { fprintf(stderr, "::error title=Shim harness assertion::%s\n", message); return 1; } while (0)
#define CHECK(condition, message) do { if (!(condition)) FAIL(message); } while (0)

static void set_receive_timeout(int socket_fd) {
    struct timeval timeout = { .tv_sec = 3, .tv_usec = 0 };
    setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
}

static int make_udp_receiver(struct sockaddr_in *address) {
    int receiver = socket(AF_INET, SOCK_DGRAM, 0);
    if (receiver < 0) {
        return -1;
    }
    set_receive_timeout(receiver);
    memset(address, 0, sizeof(*address));
    address->sin_family = AF_INET;
    address->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(receiver, (const struct sockaddr *)address, sizeof(*address)) != 0) {
        close(receiver);
        return -1;
    }
    socklen_t length = sizeof(*address);
    if (getsockname(receiver, (struct sockaddr *)address, &length) != 0) {
        close(receiver);
        return -1;
    }
    return receiver;
}

static int test_udp_preamble(void) {
    struct sockaddr_in destination;
    int receiver = make_udp_receiver(&destination);
    CHECK(receiver >= 0, "Could not create UDP receiver.");
    int sender = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(sender >= 0, "Could not create UDP sender.");

    unsigned char original[74];
    memset(original, 0x4a, sizeof(original));
    CHECK(sendto(sender, original, sizeof(original), 0, (const struct sockaddr *)&destination,
        sizeof(destination)) == (ssize_t)sizeof(original), "Original UDP send failed.");

    unsigned char received[128];
    ssize_t length = recvfrom(receiver, received, sizeof(received), 0, NULL, NULL);
    CHECK(length == 11 && memcmp(received, "packet-test", 11) == 0, "Optional packet was not injected first.");
    length = recvfrom(receiver, received, sizeof(received), 0, NULL, NULL);
    CHECK(length == 1 && received[0] == 0, "UDP zero preamble was not injected.");
    length = recvfrom(receiver, received, sizeof(received), 0, NULL, NULL);
    CHECK(length == 1 && received[0] == 1, "UDP one preamble was not injected.");
    length = recvfrom(receiver, received, sizeof(received), 0, NULL, NULL);
    CHECK(length == (ssize_t)sizeof(original) && memcmp(received, original, sizeof(original)) == 0,
        "Original UDP datagram did not follow the preamble.");
    close(sender);
    close(receiver);
    puts("UDP preamble injection passed.");
    return 0;
}

static int make_tcp_listener(struct sockaddr_in *address) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) {
        return -1;
    }
    int enabled = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));
    memset(address, 0, sizeof(*address));
    address->sin_family = AF_INET;
    address->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, (const struct sockaddr *)address, sizeof(*address)) != 0 || listen(listener, 1) != 0) {
        close(listener);
        return -1;
    }
    socklen_t length = sizeof(*address);
    if (getsockname(listener, (struct sockaddr *)address, &length) != 0) {
        close(listener);
        return -1;
    }
    return listener;
}

static int connect_tcp_client(const struct sockaddr_in *address) {
    int client = socket(AF_INET, SOCK_STREAM, 0);
    if (client < 0) {
        return -1;
    }
    if (connect(client, (const struct sockaddr *)address, sizeof(*address)) != 0) {
        close(client);
        return -1;
    }
    return client;
}

static int test_http_auth(void) {
    struct sockaddr_in address;
    int listener = make_tcp_listener(&address);
    CHECK(listener >= 0, "Could not create TCP listener.");
    int client = connect_tcp_client(&address);
    CHECK(client >= 0, "Could not connect TCP client.");
    int server = accept(listener, NULL, NULL);
    CHECK(server >= 0, "Could not accept TCP client.");
    set_receive_timeout(client);
    set_receive_timeout(server);

    const char request[] =
        "CONNECT discord.com:443 HTTP/1.1\r\n"
        "Host: discord.com:443\r\n"
        "User-Agent: XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX\r\n\r\n";
    CHECK(send(client, request, sizeof(request) - 1, 0) == (ssize_t)(sizeof(request) - 1),
        "HTTP CONNECT send failed.");
    char received[512] = {0};
    CHECK(recv(server, received, sizeof(received) - 1, 0) > 0, "HTTP proxy received no request.");
    CHECK(strstr(received, "Proxy-Authorization: Basic dXNlcjpwYXNz") != NULL,
        "HTTP proxy authentication header was not injected.");
    CHECK(strstr(received, "User-Agent:") == NULL, "HTTP authorization did not replace User-Agent.");
    close(server);
    close(client);
    close(listener);
    puts("HTTP authentication injection passed.");
    return 0;
}

typedef struct {
    int socket;
    bool success;
} socks_server_state_t;

static bool read_exact(int socket_fd, unsigned char *buffer, size_t length) {
    while (length > 0) {
        ssize_t received = recv(socket_fd, buffer, length, 0);
        if (received <= 0) {
            return false;
        }
        buffer += received;
        length -= (size_t)received;
    }
    return true;
}

static void *serve_socks5(void *context) {
    socks_server_state_t *state = context;
    unsigned char greeting[3];
    unsigned char request[128];
    unsigned char greeting_reply[] = {0x05, 0x00};
    if (!read_exact(state->socket, greeting, sizeof(greeting)) ||
        memcmp(greeting, (unsigned char[]){0x05, 0x01, 0x00}, sizeof(greeting)) != 0 ||
        send(state->socket, greeting_reply, sizeof(greeting_reply), 0) != (ssize_t)sizeof(greeting_reply)) {
        return NULL;
    }
    if (!read_exact(state->socket, request, 5) || request[0] != 0x05 ||
        request[1] != 0x01 || request[3] != 0x03) {
        return NULL;
    }
    unsigned char host_length = request[4];
    if (host_length == 0 || host_length > 100 ||
        !read_exact(state->socket, request + 5, (size_t)host_length + 2)) {
        return NULL;
    }
    const char expected_host[] = "voice.example.com";
    if (host_length != sizeof(expected_host) - 1 ||
        memcmp(request + 5, expected_host, sizeof(expected_host) - 1) != 0 ||
        request[5 + host_length] != 0x01 || request[6 + host_length] != 0xbb) {
        return NULL;
    }
    unsigned char success[] = {0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    if (send(state->socket, success, sizeof(success), 0) != (ssize_t)sizeof(success)) {
        return NULL;
    }
    state->success = true;
    return NULL;
}

static int test_socks5_translation(void) {
    struct sockaddr_in address;
    int listener = make_tcp_listener(&address);
    CHECK(listener >= 0, "Could not create SOCKS5 listener.");
    int client = connect_tcp_client(&address);
    CHECK(client >= 0, "Could not connect SOCKS5 client.");
    int server = accept(listener, NULL, NULL);
    CHECK(server >= 0, "Could not accept SOCKS5 client.");
    set_receive_timeout(client);
    set_receive_timeout(server);
    socks_server_state_t state = { .socket = server, .success = false };
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, serve_socks5, &state) == 0, "Could not start SOCKS5 thread.");
    const char connect_request[] =
        "CONNECT voice.example.com:443 HTTP/1.1\r\nHost: voice.example.com:443\r\n\r\n";
    CHECK(send(client, connect_request, sizeof(connect_request) - 1, 0) == (ssize_t)(sizeof(connect_request) - 1),
        "SOCKS5 CONNECT conversion failed.");
    char reply[128] = {0};
    CHECK(recv(client, reply, sizeof(reply) - 1, 0) > 0 &&
        strstr(reply, "HTTP/1.1 200 Connection Established") != NULL,
        "SOCKS5 reply was not exposed as HTTP success.");
    pthread_join(thread, NULL);
    CHECK(state.success, "SOCKS5 server did not receive the translated request.");
    close(server);
    close(client);
    close(listener);
    puts("SOCKS5 translation passed.");
    return 0;
}

int main(int argc, char **argv) {
    setbuf(stdout, NULL);
    setbuf(stderr, NULL);
    if (argc != 2) {
        fprintf(stderr, "Usage: %s udp|http|socks5\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "udp") == 0) return test_udp_preamble();
    if (strcmp(argv[1], "http") == 0) return test_http_auth();
    if (strcmp(argv[1], "socks5") == 0) return test_socks5_translation();
    FAIL("Unknown test name.");
}
