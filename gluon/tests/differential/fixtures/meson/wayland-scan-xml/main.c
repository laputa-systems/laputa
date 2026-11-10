#include "sample-client-protocol.h"
#include "sample-server-protocol.h"
int main(void) { return sample_thing_interface.version == 1 ? 0 : 1; }
