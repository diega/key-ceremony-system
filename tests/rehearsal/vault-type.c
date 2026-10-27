/* Rehearsal only: type TEXT and Enter on tty1 through a virtual input
 * keyboard (uinput), using the same tty path as a physical USB keyboard.
 * Accept only [a-z0-9-], at most 64 characters, for disposable passphrases.
 * Callers cannot select control keys; Enter is appended automatically. */
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static const struct { char c; int code; } keys[] = {
  {'a', KEY_A}, {'b', KEY_B}, {'c', KEY_C}, {'d', KEY_D}, {'e', KEY_E},
  {'f', KEY_F}, {'g', KEY_G}, {'h', KEY_H}, {'i', KEY_I}, {'j', KEY_J},
  {'k', KEY_K}, {'l', KEY_L}, {'m', KEY_M}, {'n', KEY_N}, {'o', KEY_O},
  {'p', KEY_P}, {'q', KEY_Q}, {'r', KEY_R}, {'s', KEY_S}, {'t', KEY_T},
  {'u', KEY_U}, {'v', KEY_V}, {'w', KEY_W}, {'x', KEY_X}, {'y', KEY_Y},
  {'z', KEY_Z}, {'0', KEY_0}, {'1', KEY_1}, {'2', KEY_2}, {'3', KEY_3},
  {'4', KEY_4}, {'5', KEY_5}, {'6', KEY_6}, {'7', KEY_7}, {'8', KEY_8},
  {'9', KEY_9}, {'-', KEY_MINUS},
};
#define NKEYS (sizeof keys / sizeof keys[0])

static int fd;

static int code_of(char c) {
  for (size_t i = 0; i < NKEYS; i++)
    if (keys[i].c == c) return keys[i].code;
  return -1;
}

static void emit(int type, int code, int value) {
  struct input_event ev;
  memset(&ev, 0, sizeof ev);
  ev.type = type;
  ev.code = code;
  ev.value = value;
  if (write(fd, &ev, sizeof ev) != sizeof ev) _exit(1);
}

static void press(int code) {
  emit(EV_KEY, code, 1);
  emit(EV_SYN, SYN_REPORT, 0);
  usleep(30000);
  emit(EV_KEY, code, 0);
  emit(EV_SYN, SYN_REPORT, 0);
  usleep(30000);
}

int main(int argc, char **argv) {
  if (argc != 2 || strlen(argv[1]) == 0 || strlen(argv[1]) > 64) {
    fprintf(stderr, "usage: vault-type TEXT ([a-z0-9-], 1-64 chars)\n");
    return 2;
  }
  for (const char *p = argv[1]; *p; p++)
    if (code_of(*p) < 0) {
      fprintf(stderr, "vault-type: only [a-z0-9-]\n");
      return 2;
    }

  fd = open("/dev/uinput", O_WRONLY | O_CLOEXEC);
  if (fd < 0) { perror("vault-type: /dev/uinput"); return 1; }
  if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) { perror("vault-type"); return 1; }
  for (size_t i = 0; i < NKEYS; i++) ioctl(fd, UI_SET_KEYBIT, keys[i].code);
  ioctl(fd, UI_SET_KEYBIT, KEY_ENTER);

  struct uinput_setup setup;
  memset(&setup, 0, sizeof setup);
  setup.id.bustype = BUS_VIRTUAL;
  strcpy(setup.name, "pgp-vault rehearsal keyboard");
  if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
    perror("vault-type: creating the keyboard");
    return 1;
  }
  sleep(1); /* the console's keyboard handler attaches to it */

  for (const char *p = argv[1]; *p; p++) press(code_of(*p));
  press(KEY_ENTER);

  sleep(1);
  ioctl(fd, UI_DEV_DESTROY);
  close(fd);
  return 0;
}
