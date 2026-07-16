#include "mongoose.h"
int main(void) {
    struct mg_mgr mgr;
    mg_mgr_init(&mgr);
    mg_mgr_free(&mgr);
    return 0;
}
