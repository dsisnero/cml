#!/bin/bash
# Demo setup script - creates source files for the build system example

echo "Creating demo source files..."

# Create source files
cat > main.c << 'EOF'
#include "util.h"

int main() {
    say_hello();
    return 0;
}
EOF

cat > util.c << 'EOF'
#include <stdio.h>
#include "util.h"

void say_hello() {
    printf("Hello from CML build system!\n");
}
EOF

cat > util.h << 'EOF'
#ifndef UTIL_H
#define UTIL_H

void say_hello(void);

#endif
EOF

echo "Demo files created: main.c, util.c, util.h"
echo ""
echo "Now you can run the build system:"
echo "  crystal run build_system.cr -- example.makefile"
