// Потребитель заголовков rapidjson. Ничего не линкует: библиотеки у пакета нет.
#include "rapidjson/document.h"
#include "rapidjson/stringbuffer.h"
#include "rapidjson/writer.h"

#include <cstdio>

int main()
{
    rapidjson::Document d;
    d.Parse("{\"slot\":\"legacy\"}");
    if (d.HasParseError() || !d.HasMember("slot")) {
        std::puts("FAIL: parse");
        return 1;
    }

    rapidjson::StringBuffer buf;
    rapidjson::Writer<rapidjson::StringBuffer> w(buf);
    d.Accept(w);
    std::printf("OK %s\n", buf.GetString());
    return 0;
}
