#include <wayland-client.h>
extern const struct wl_interface zwp_text_input_v3_interface;
extern const struct wl_interface zwp_text_input_v1_interface;
extern const struct wl_interface xdg_shell_interface;
extern const struct wl_interface zxdg_shell_v6_interface;
extern const struct wl_interface wp_fifo_v1_interface;
int main(void) {
  return !(&zwp_text_input_v1_interface && &xdg_shell_interface && &zwp_text_input_v3_interface && &zxdg_shell_v6_interface && &wp_fifo_v1_interface);
}
