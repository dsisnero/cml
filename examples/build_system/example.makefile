# Example Makefile for the parallel build system demo
# This shows dependencies between files

prog : main.o util.o
	echo "Linking prog from main.o util.o" && touch prog

main.o : main.c util.h
	echo "Compiling main.c" && touch main.o

util.o : util.c util.h
	echo "Compiling util.c" && touch util.o
