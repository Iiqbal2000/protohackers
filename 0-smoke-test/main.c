#include <asm-generic/socket.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#define MAX_BUF 1024

void *conn_handler(void *var_client_fd) {
  printf("spawning thread %lu\n", pthread_self());

  char *msg_buffer = malloc(MAX_BUF);
  memset(msg_buffer, 0, MAX_BUF);

  int client_fd = *((int *)var_client_fd);

  int received_byte;
  while ((received_byte = recv(client_fd, msg_buffer, MAX_BUF - 1, 0)) > 0) {
    write(client_fd, msg_buffer, received_byte);
  }

  if (received_byte < 0) {
    perror("cannot receive client message");
    close(client_fd);
    free(msg_buffer);
    free(var_client_fd);
    return (void *)-1;
  } else if (received_byte == 0) {
    close(client_fd);
    free(msg_buffer);
    free(var_client_fd);
    return (void *)0;
  }

  printf("read %d bytes\n", received_byte);

  msg_buffer[received_byte] = '\0';

  if (send(client_fd, msg_buffer, strlen(msg_buffer), 0) < 0) {
    perror("cannot send message back");
    close(client_fd);
    free(msg_buffer);
    free(var_client_fd);
    return (void *)-1;
  }

  free(msg_buffer);
  close(client_fd);
  free(var_client_fd);
  return (void *)0;
}

int main() {
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

    thread_err_code = pthread_create(&tid, NULL, conn_handler, (void *)cp_client_fd);
    if (thread_err_code) {
      printf("ERROR; return code from pthread_create() is %d\n", thread_err_code);
      close(client_fd);
      free(cp_client_fd);
    }
  }

  return EXIT_SUCCESS;
}
