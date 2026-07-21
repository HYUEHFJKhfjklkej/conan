#include <snap7.h>
#include <stdio.h>

int main() {
    S7Object client = Cli_Create();
    int connected = -1;
    Cli_GetConnected(client, &connected);
    Cli_Destroy(&client);

    TS7Client cpp_client;
    printf("snap7 ok: C API connected=%d, TS7Client connected=%d\n",
           connected, cpp_client.Connected() ? 1 : 0);
    return 0;
}
