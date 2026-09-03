// Заголовок под moc: проверяет, что include-каталоги зависимости видны и
// при генерации mocs_compilation.cpp, а не только при сборке main.cpp.
#pragma once

#include <QObject>

#include "rapidjson/document.h"

class QtUser : public QObject
{
    Q_OBJECT
public:
    explicit QtUser(QObject* parent = nullptr);

    bool parse(const char* json);

private:
    rapidjson::Document m_doc;
};
