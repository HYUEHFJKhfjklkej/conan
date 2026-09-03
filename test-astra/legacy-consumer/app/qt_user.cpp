#include "qt_user.h"

QtUser::QtUser(QObject* parent) : QObject(parent) {}

bool QtUser::parse(const char* json)
{
    m_doc.Parse(json);
    return !m_doc.HasParseError();
}
