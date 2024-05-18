#include "btree.h"
#include <asm-generic/socket.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#define MAX_BUF 1024 * 10
#define MESSAGE_LEN 9

pthread_mutex_t tree_mutex;

struct historical_price {
  int timestamp;
  int price;
} typedef historical_price;

// Comparison function for historical_price structs
int compare_historical_price(const void *a, const void *b, void *udata) {
  (void)udata; // Unused
  const historical_price *ha = (const historical_price *)a;
  const historical_price *hb = (const historical_price *)b;
  return ha->timestamp - hb->timestamp;
}

// Function to print a historical price
void print_historical_price(const historical_price *hp) {
  printf("Timestamp: %d, Price: %d\n", hp->timestamp, hp->price);
}

struct query_result {
  int mintime;
  int maxtime;
  historical_price *prices; // Array to store matching prices
  int cap;                  // Capacity of the array
  int count;                // Number of prices found
} typedef query_result;

bool price_iter(const void *item, void *udata) {
  historical_price *hp = (historical_price *)item;
  query_result *q = (query_result *)udata;
  if (hp->timestamp > q->maxtime) {
    return false; // Stop iteration
  }

  if (q->count == q->cap) {
    // Resize the array
    q->cap = (q->cap == 0) ? 1 : q->cap * 2; // Double the capacity
    void *tmp = realloc(q->prices, q->cap * sizeof(historical_price));
    if (!tmp) {
      return false;
    }
    q->prices = tmp;
  }

  ((historical_price *)q->prices)[q->count] = *hp;
  q->count++;
  return true; // Continue iteration
}

query_result prices_in_range(struct btree *tree, int start_ts, int end_ts) {
  historical_price pivot = {.timestamp = start_ts};
  query_result q = {
      .mintime = start_ts,
      .maxtime = end_ts,
      .prices = NULL,
      .cap = 0,
      .count = 0};

  btree_ascend(tree, &pivot, price_iter, &q);
  return q;
}

void insert(struct btree *tree, unsigned char bytes_buffer[MESSAGE_LEN]) {
  int timestamp = (bytes_buffer[1] << 24) | (bytes_buffer[2] << 16) | (bytes_buffer[3] << 8) | bytes_buffer[4];
  int price = (bytes_buffer[5] << 24) | (bytes_buffer[6] << 16) | (bytes_buffer[7] << 8) | bytes_buffer[8];
  historical_price entry = {
      .timestamp = timestamp,
      .price = price};

  btree_set(tree, &entry);

  // printf("%c ", bytes_buffer[0]);
  // printf("%d ", timestamp);
  // printf("%d\n", price);
}

int32_t query(struct btree *tree, unsigned char bytes_buffer[MESSAGE_LEN]) {
  int mintime = (bytes_buffer[1] << 24) | (bytes_buffer[2] << 16) | (bytes_buffer[3] << 8) | bytes_buffer[4];
  int maxtime = (bytes_buffer[5] << 24) | (bytes_buffer[6] << 16) | (bytes_buffer[7] << 8) | bytes_buffer[8];

  if (mintime > maxtime) {
    return 0;
  }

  int64_t sum = 0;
  query_result result = prices_in_range(tree, mintime, maxtime);
  for (int i = 0; i < result.count; i++) {
    sum += (result.prices[i]).price;
  }

  if (result.count > 0) {
    int64_t mean = sum / result.count;
    printf("Mean price for timestamps between %d and %d: %ld / %d = %ld\n",
           mintime, maxtime, sum, result.count, mean);
    free(result.prices);
    return (int32_t)mean;
  }
  printf("No prices found for the specified time range.\n");
  free(result.prices);
  return 0;
}

struct conn_handler_param {
  int *client_fd;
  struct btree *tree;
} typedef conn_handler_param;


void *conn_handler(void *params) {
  printf("spawning thread %lu\n", pthread_self());
  conn_handler_param *param = (conn_handler_param *)params;

  unsigned char msg_buffer[MAX_BUF];

  unsigned char bytes_buffer[MESSAGE_LEN];
  int written_byte = 0;
  int received_byte;

  while ((received_byte = recv(*(param->client_fd), msg_buffer, MAX_BUF, 0)) > 0) {
    // printf("read %d bytes\n", received_byte);

    for (int i = 0; i < received_byte; i++) {
      bytes_buffer[written_byte] = msg_buffer[i];
      written_byte++;
      if (written_byte == MESSAGE_LEN) {
        int32_t mean;
        switch (bytes_buffer[0]) {
        case 'I':
          // pthread_mutex_lock(&tree_mutex);
          insert(param->tree, bytes_buffer);
          // pthread_mutex_unlock(&tree_mutex);

          break;
        case 'Q':
          // pthread_mutex_lock(&tree_mutex);
          mean = query(param->tree, bytes_buffer);
          mean = htonl(mean);
          write(*(param->client_fd), &mean, sizeof(int));
          // pthread_mutex_unlock(&tree_mutex);

          break;
        default:
          perror("Bad packet");
        }

        written_byte = 0;
      }
    }
  }

  if (received_byte < 0) {
    perror("cannot receive client message");
    close(*(param->client_fd));
    return (void *)-1;
  }

  free(param->tree);
  close(*(param->client_fd));
  printf("closed connection with returning success\n");
  return (void *)0;
}

int main() {
  pthread_mutex_init(&tree_mutex, NULL);

  // struct btree *tree = btree_new(sizeof(historical_price), 0,
  //                                compare_historical_price, NULL);

  int socket_fd = socket(AF_INET, SOCK_STREAM, getprotobyname("tcp")->p_proto);
  if (socket_fd < 0) {
    perror("cannot create a socket");
    exit(EXIT_FAILURE);
  }

  const int on = 1;
  setsockopt(socket_fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

  struct sockaddr_in server;
  server.sin_family = AF_INET;
  server.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  server.sin_port = htons(8000);

  if (bind(socket_fd, (struct sockaddr *)&server, sizeof(server)) < 0) {
    perror("bind failed");
    exit(EXIT_FAILURE);
  }

  if (listen(socket_fd, 10) < 0) {
    perror("listen failed");
    exit(EXIT_FAILURE);
  }

  puts("waiting for incoming connections...");

  struct sockaddr_in client;
  int client_fd;
  int client_sock_len = sizeof(struct sockaddr_in);
  pthread_t tid;
  int thread_err_code;

  for (;;) {
    client_fd = accept(socket_fd, (struct sockaddr *)&client, (socklen_t *)&client_sock_len);
    if (client_fd < 0) {
      perror("cannot accept a connection");
      continue;
    }

    printf("a new connection accepted with %d fd\n", client_fd);

    int *cp_client_fd = malloc(sizeof(int));
    if (cp_client_fd == NULL) {
      perror("cannot allocate a copy of client fd");
      continue;
    }

    *cp_client_fd = client_fd;

    // Each connection represents a different asset, so each connection can only query the data supplied by itself
    struct btree *db = btree_new(sizeof(historical_price), 0,
                                 compare_historical_price, NULL);

    conn_handler_param *param = malloc(sizeof(conn_handler_param));
    param->client_fd = cp_client_fd;
    param->tree = db;

    thread_err_code = pthread_create(&tid, NULL, conn_handler, (void *)param);
    if (thread_err_code) {
      printf("ERROR; return code from pthread_create() is %d\n", thread_err_code);
      close(client_fd);
      free(cp_client_fd);
    }
  }


  return EXIT_SUCCESS;
}
