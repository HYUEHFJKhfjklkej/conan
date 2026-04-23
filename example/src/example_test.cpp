#include <gtest/gtest.h>
#include "example.hpp"

TEST(ExampleTest, Add) {
    EXPECT_EQ(add(2, 3), 5);
    EXPECT_EQ(add(-1, 1), 0);
    EXPECT_EQ(add(0, 0), 0);
}

TEST(ExampleTest, Multiply) {
    EXPECT_EQ(multiply(2, 3), 6);
    EXPECT_EQ(multiply(-1, 5), -5);
    EXPECT_EQ(multiply(0, 100), 0);
}
