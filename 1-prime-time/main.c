#include "jsmn.h"
#include <asm-generic/socket.h>
#include <errno.h>
#include <float.h>
#include <limits.h>
#include <math.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#define MAX_BUF 1024 * 100
#define JSMN_STRICT 1

bool is_prime(int num) {
  if (num <= 1)
    return false;
  if (num <= 3)
    return true;
  if (num % 2 == 0 || num % 3 == 0)
    return false;
  // Only check up to the square root of num
  for (int i = 5; i * i <= num; i += 6) {
    if (num % i == 0 || num % (i + 2) == 0)
      return false;
  }

  return true;
}

int jsoneq(const char *json_input, jsmntok_t *tok, const char *json_key) {
  if (tok->type == JSMN_STRING && (int)strlen(json_key) == tok->end - tok->start && strncmp(json_input + tok->start, json_key, tok->end - tok->start) == 0) {
    return 0;
  }

  return -1;
}

int is_float(const char *str, int start, int end) {
  for (int i = start; i < end; i++) {
    if (str[i] == '.') {
      return 1;
    }
  }

  return 0;
}

int validate_numeric(const char *buff) {
  if (buff == NULL) {
    fprintf(stderr, "Null string provided\n");
    return 0;
  }

  char *end;
  errno = 0;
  double sd = strtod(buff, &end);

  if (end == buff) {
    // fprintf(stderr, "%s: not a number\n", buff);
    return 0;
  }

  // else if ('\0' != *end) {
  //   fprintf(stderr, "%s: extra characters at end of input: %s\n", buff, end);
  // }

  else if ((DBL_MAX == sd || DBL_MIN == sd) && ERANGE == errno) {
    // fprintf(stderr, "%s out of range of type double\n", buff);
    return 0;
  } else {
    // Check for integer-specific constraints if needed
    if (sd == (double)(long)sd) {
      if (sd > INT_MAX || sd < INT_MIN) {
        // fprintf(stderr, "%f is out of integer range but is a valid float\n", sd);
        return 1;
      } else {
        // fprintf(stderr, "%f is a valid integer value\n", sd);
        return 1;
      }
    } else {
      // fprintf(stderr, "%f is a valid float\n", sd);
      return 1;
    }
    return 1; // Successfully parsed as a number
  }

  return 0;
}

char *parse_data(char *new_line_tok) {
  int num_tokens;
  jsmn_parser parser;
  jsmntok_t *tokens = NULL;
  int success_parse = 0;
  int token_size = 100;

  char *msg_resp = malloc(MAX_BUF);
  if (!msg_resp) {
    perror("Allocation failed for msg_resp");
    free(msg_resp);
    return NULL;
  }

  while (!success_parse) {
    free(tokens);
    tokens = malloc(sizeof(jsmntok_t) * token_size);
    if (!tokens) {
      perror("Allocation failed for tokens");
      free(msg_resp);
      return NULL;
    }

    jsmn_init(&parser);
    num_tokens = jsmn_parse(&parser, new_line_tok, strlen(new_line_tok), tokens, token_size);
    if (num_tokens < 0) {
      if (num_tokens == JSMN_ERROR_NOMEM) {
        token_size *= 2;
      } else {
        // printf("Failed to parse JSON with code %d\n", num_tokens);
        free(tokens);
        tokens = NULL; // Ensure tokens is NULL if not valid
        sprintf(msg_resp, "{}\n");
        return msg_resp;
      }
    } else {
      success_parse = 1;
    }
  }

  if (!tokens || tokens[0].type != JSMN_OBJECT) {
    // printf("invalid JSON (not JSON object): %s\n", new_line_tok);
    sprintf(msg_resp, "{}\n");
    free(tokens); // Free tokens after processing
    return msg_resp;
  }

  int method_found = 0;
  int number_found = 0;
  for (int i = 0; i < num_tokens; i++) {
    if (jsoneq(new_line_tok, &tokens[i], "method") == 0) {
      if (strncmp(new_line_tok + tokens[i + 1].start, "isPrime", tokens[i + 1].end - tokens[i + 1].start) == 0) {
        method_found = 1;
      }
      i++;
    } else if (jsoneq(new_line_tok, &tokens[i], "number") == 0 && tokens[i + 1].type == JSMN_PRIMITIVE) {
      int start = tokens[i + 1].start;
      int end = tokens[i + 1].end;

      if (!validate_numeric(new_line_tok + start)) {
        sprintf(msg_resp, "{}\n");
        free(tokens); // Free tokens after processing
        return msg_resp;
      }

      number_found = 1;

      if (is_float(new_line_tok, start, end)) {
        double fval = atof(new_line_tok + start);
        // printf("value: %f (float)\n", fval);
        if (fabs(fval - floor(fval)) > 0.000001) {
          snprintf(msg_resp, MAX_BUF, "{\"method\":\"isPrime\",\"prime\":false}\n");
        } else {
          snprintf(msg_resp, MAX_BUF, "{\"method\":\"isPrime\",\"prime\":%s}\n", is_prime((int)fval) ? "true" : "false");
        }
      } else {
        int ival = atoi(new_line_tok + start);
        // printf("value: %d (integer)\n", ival);
        snprintf(msg_resp, MAX_BUF, "{\"method\":\"isPrime\",\"prime\":%s}\n", is_prime(ival) ? "true" : "false");
      }
      i++;
    }
  }

  if (!(method_found && number_found)) {
    // printf("invalid JSON: %s\n", new_line_tok);
    sprintf(msg_resp, "{}\n");
  }
  free(tokens); // Free tokens after processing
  return msg_resp;
}

void *conn_handler(void *var_client_fd) {
  printf("spawning thread %lu\n", pthread_self());

  char *msg_buffer = malloc(MAX_BUF);
  if (!msg_buffer) {
    perror("Allocation failed for msg_buffer");
    return (void *)-1;
  }

  memset(msg_buffer, 0, MAX_BUF);

  int client_fd = *((int *)var_client_fd);
  // free(var_client_fd);

  int received_byte;
  while ((received_byte = recv(client_fd, msg_buffer, MAX_BUF - 1, 0)) > 0) {
    printf("read %d bytes\n", received_byte);

    msg_buffer[received_byte] = '\0';

    printf("msg buffer: %s\n", msg_buffer);

    if (strchr(msg_buffer, '\n') == NULL && strchr(msg_buffer, '{') == NULL) {
      printf("msg doesn't contain a new line\n");
      if (write(client_fd, "{}\n", strlen("{}\n")) < 0) {
        perror("cannot send message back");
        close(client_fd);
        free(msg_buffer);
        return (void *)-1;
      }
      close(client_fd);
      printf("closed connection with failed\n");
      return (void *)-1;
    }

    if (strchr(msg_buffer, '\n') == NULL && strchr(msg_buffer, '{') != NULL) {
      char *tmp_buf = malloc(MAX_BUF);
      while (read(client_fd, tmp_buf, MAX_BUF - 1) > 0) {
        printf("tmp buff: %s\n", tmp_buf);
        strcat(msg_buffer, tmp_buf);
        if (strchr(tmp_buf, '}') != NULL && strchr(tmp_buf, '\n')) {
          break;
        }
      }
      free(tmp_buf);
    }

    char *msg_buffer_copy = msg_buffer;
    // split messages by new line
    char *new_line_tok = strtok_r(msg_buffer_copy, "\n", &msg_buffer_copy);
    while (new_line_tok != NULL) {
      char *msg_resp = parse_data(new_line_tok);
      if (msg_resp == NULL) {
        return (void *)-1;
      } else {
        printf("received msg: %s\n", new_line_tok);
        printf("response msg: %s\n", msg_resp);
        if (write(client_fd, msg_resp, strlen(msg_resp)) < 0) {
          perror("cannot send message back");
          free(msg_resp);
          close(client_fd);
          free(msg_buffer);
          return (void *)-1;
        }
      }

      new_line_tok = strtok_r(NULL, "\n", &msg_buffer_copy);
    }
  }

  if (received_byte < 0) {
    perror("cannot receive client message");
    close(client_fd);
    free(msg_buffer);
    return (void *)-1;
  }

  close(client_fd);
  printf("closed connection with returning success\n");
  free(msg_buffer);
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
