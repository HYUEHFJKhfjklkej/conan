#include <pb_encode.h>
#include <pb_decode.h>
int main(void){
    pb_byte_t buf[16];
    pb_ostream_t s = pb_ostream_from_buffer(buf, sizeof(buf));
    return s.max_size == sizeof(buf) ? 0 : 1;
}
