# Task: Create a Hello World Project

Create the following three files.

## 1. hello.py

Create `hello.py` with:
- Use `argparse` to accept an optional `--name` argument (default: "World")
- Print `Hello, {name}!` (must use the word "Hello" with a capital H, followed by a comma and space)
- Wrap logic in a `main()` function called via `if __name__ == '__main__'`

## 2. test_hello.py

Create `test_hello.py` with pytest tests:
- `test_default_output`: assert running `python hello.py` prints "Hello, World!"
- `test_custom_name`: assert running `python hello.py --name Alice` prints "Hello, Alice!"
- Use `subprocess.run` to invoke the script

## 3. pyproject.toml

Create `pyproject.toml` with:
- Project name: "hello-world", version: "0.1.0"
- Requires Python >=3.10
- pytest as a dev dependency

## Completion

When all files are created and working, output: LOOP_COMPLETE
