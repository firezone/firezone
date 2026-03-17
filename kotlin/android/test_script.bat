@echo off
echo Testing Execution >> test_output.txt
cargo --version >> test_output.txt 2>&1
java -version >> test_output.txt 2>&1
echo Done >> test_output.txt
