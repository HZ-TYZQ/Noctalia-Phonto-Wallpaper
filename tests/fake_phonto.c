/* Stand-in for phonto in the real-process tests: it keeps its command line in
 * /proc and takes the default action for every signal (SIGTERM ends it, SIGSTOP
 * and SIGCONT pause and resume it), but renders nothing. Like a real phonto
 * given an unplayable video, it fails at once when a path contains "/broken/". */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    if (strstr(argv[i], "/broken/")) {
      fprintf(stderr, "fake phonto: cannot play %s\n", argv[i]);
      return 1;
    }
  }
  for (;;) pause();
}
