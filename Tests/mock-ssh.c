// 接受任意 SSH 参数并保持存活，不建立网络连接。
#include <unistd.h>

int main(void) {
    for (;;) pause();
}
