#include <cerrno>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#if defined(_WIN32)
#include <windows.h>
#include <direct.h>
#include <process.h>
#include <sys/stat.h>
#define getcwd _getcwd
#define stat _stat
#else
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace {

constexpr const char* kPwdPlaceholder = "${pwd}";
constexpr const char* kOutputBasePlaceholder = "${output_base}";
constexpr const char* kExecRootPlaceholder = "${exec_root}";

#if defined(_WIN32)
constexpr char kPathSeparator = '\\';
#else
constexpr char kPathSeparator = '/';
#endif

bool is_directory(const std::string& path) {
  struct stat stat_buffer;
  return stat(path.c_str(), &stat_buffer) == 0 &&
         (stat_buffer.st_mode & S_IFDIR) != 0;
}

#if defined(_WIN32)
bool is_symlink(const std::string& path) {
  DWORD attrs = GetFileAttributesA(path.c_str());
  if (attrs == INVALID_FILE_ATTRIBUTES) {
    return false;
  }
  return (attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
}
#else
bool is_symlink(const std::string& path) {
  struct stat stat_buffer;
  return lstat(path.c_str(), &stat_buffer) == 0 && S_ISLNK(stat_buffer.st_mode);
}
#endif

std::string dirname(const std::string& path) {
  std::string::size_type slash = path.find_last_of("/\\");
  if (slash == std::string::npos) {
    return path;
  }
  if (slash == 0) {
    return path.substr(0, 1);
  }
  return path.substr(0, slash);
}

std::string basename(const std::string& path) {
  std::string::size_type slash = path.find_last_of("/\\");
  if (slash == std::string::npos) {
    return path;
  }
  return path.substr(slash + 1);
}

std::string join_path(const std::string& left, const std::string& right) {
  if (left.empty()) {
    return right;
  }
  if (left.back() == '/' || left.back() == '\\') {
    return left + right;
  }
  return left + kPathSeparator + right;
}

std::string canonicalize(const std::string& path) {
#if defined(_WIN32)
  char* resolved = _fullpath(nullptr, path.c_str(), 0);
#else
  char* resolved = realpath(path.c_str(), nullptr);
#endif
  if (resolved == nullptr) {
    return path;
  }
  std::string out = resolved;
  std::free(resolved);
  return out;
}

std::string replace_all(std::string out,
                        const std::string& placeholder,
                        const std::string& replacement) {
  std::string::size_type pos = 0;
  while ((pos = out.find(placeholder, pos)) != std::string::npos) {
    out.replace(pos, placeholder.size(), replacement);
    pos += replacement.size();
  }
  return out;
}

std::string replace_placeholders(const std::string& arg,
                                 const std::string& pwd,
                                 const std::string& output_base,
                                 const std::string& exec_root) {
  std::string out = arg;
  out = replace_all(out, kPwdPlaceholder, pwd);
  out = replace_all(out, kOutputBasePlaceholder, output_base);
  out = replace_all(out, kExecRootPlaceholder, exec_root);
  return out;
}

std::string get_output_base(const std::string& pwd) {
  // The traditional Bazel layout has `external` as a symlink whose target's
  // parent is the output base. Newer Windows layouts (Bazel >= 9.0.1) place
  // a real `external` directory inside execroot instead, in which case
  // canonicalizing `external/..` yields `pwd` (the execroot), not the output
  // base. Only trust the symlink path; otherwise derive output_base from
  // `pwd`'s grandparent (`<output_base>/execroot/<ws>` → `<output_base>`).
  const std::string external = join_path(pwd, "external");
  if (is_symlink(external)) {
    return canonicalize(join_path(external, ".."));
  }
  return dirname(dirname(canonicalize(pwd)));
}

std::vector<char*> build_exec_argv(const std::vector<std::string>& args) {
  std::vector<char*> exec_argv;
  exec_argv.reserve(args.size() + 1);
  for (const std::string& arg : args) {
    exec_argv.push_back(const_cast<char*>(arg.c_str()));
  }
  exec_argv.push_back(nullptr);
  return exec_argv;
}

#if defined(_WIN32)
// Convert a path to its 8.3 short form. The path must exist for the
// conversion to succeed; if it doesn't, walks back to the longest existing
// prefix, takes its short form, and re-appends the missing tail unchanged.
// Returns the input unchanged when no part of the path resolves.
std::string to_short_path(const std::string& path) {
  if (path.empty()) {
    return path;
  }
  char buf[MAX_PATH];
  DWORD len = GetShortPathNameA(path.c_str(), buf, MAX_PATH);
  if (len > 0 && len < MAX_PATH) {
    return std::string(buf, len);
  }
  std::string::size_type sep = path.find_last_of("/\\");
  if (sep == std::string::npos || sep == 0) {
    return path;
  }
  std::string parent = path.substr(0, sep);
  std::string short_parent = to_short_path(parent);
  if (short_parent == parent) {
    return path;
  }
  return short_parent + path.substr(sep);
}

std::string make_absolute(const std::string& path, const std::string& pwd) {
  if (path.size() >= 2 && path[1] == ':') {
    return path;
  }
  if (!path.empty() && (path[0] == '/' || path[0] == '\\')) {
    return path;
  }
  return join_path(pwd, path);
}

// Rewrite a `@response-file` so that paths exceeding Windows MAX_PATH are
// expressed in 8.3 short form. Currently rewrites:
//   --sysroot=<path>             (rustc; libstd paths it derives are passed
//                                 to link.exe which doesn't honor long paths)
//
// Returns the path of a rewritten temp file, or the original path when no
// rewrite was needed or the file could not be read.
std::string rewrite_response_file(const std::string& orig_filename,
                                  const std::string& pwd) {
  std::ifstream in(orig_filename);
  if (!in.is_open()) {
    return orig_filename;
  }
  std::vector<std::string> lines;
  std::string line;
  bool modified = false;
  const std::string sysroot_prefix = "--sysroot=";
  while (std::getline(in, line)) {
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    if (line.compare(0, sysroot_prefix.size(), sysroot_prefix) == 0) {
      std::string value = line.substr(sysroot_prefix.size());
      std::string abs_value = make_absolute(value, pwd);
      std::string short_value = to_short_path(abs_value);
      if (short_value != abs_value) {
        line = sysroot_prefix + short_value;
        modified = true;
      }
    }
    lines.push_back(line);
  }
  in.close();
  if (!modified) {
    return orig_filename;
  }
  char temp_dir[MAX_PATH];
  DWORD temp_dir_len = GetTempPathA(MAX_PATH, temp_dir);
  if (temp_dir_len == 0 || temp_dir_len >= MAX_PATH) {
    return orig_filename;
  }
  char temp_file[MAX_PATH];
  if (GetTempFileNameA(temp_dir, "bpw", 0, temp_file) == 0) {
    return orig_filename;
  }
  std::ofstream out(temp_file);
  if (!out.is_open()) {
    return orig_filename;
  }
  for (const std::string& l : lines) {
    out << l << "\n";
  }
  out.close();
  return std::string(temp_file);
}

void rewrite_response_files(std::vector<std::string>& args,
                            const std::string& pwd) {
  for (std::string& arg : args) {
    if (arg.size() > 1 && arg[0] == '@') {
      std::string orig = arg.substr(1);
      std::string rewritten = rewrite_response_file(orig, pwd);
      if (rewritten != orig) {
        arg = "@" + rewritten;
      }
    }
  }
}
#endif  // _WIN32

}  // namespace

int main(int argc, char** argv) {
  int first_arg_index = 1;
  if (argc > 1 && std::strcmp(argv[1], "--") == 0) {
    first_arg_index = 2;
  }

  if (first_arg_index >= argc) {
    std::fprintf(stderr, "bootstrap_process_wrapper: missing command\n");
    return 1;
  }

  char* pwd_raw = getcwd(nullptr, 0);
  if (pwd_raw == nullptr) {
    std::perror("bootstrap_process_wrapper: getcwd");
    return 1;
  }
  std::string pwd = pwd_raw;
  std::free(pwd_raw);
  const std::string output_base = get_output_base(pwd);
  const std::string exec_root =
      join_path(join_path(output_base, "execroot"), basename(pwd));

  std::vector<std::string> command_args;
  command_args.reserve(static_cast<size_t>(argc - first_arg_index));
  for (int i = first_arg_index; i < argc; ++i) {
    command_args.push_back(
        replace_placeholders(argv[i], pwd, output_base, exec_root));
  }

#if defined(_WIN32)
  for (char& c : command_args[0]) {
    if (c == '/') {
      c = '\\';
    }
  }
  rewrite_response_files(command_args, pwd);
#endif

  std::vector<char*> exec_argv = build_exec_argv(command_args);

#if defined(_WIN32)
  int exit_code = _spawnvp(_P_WAIT, exec_argv[0], exec_argv.data());
  if (exit_code == -1) {
    std::perror("bootstrap_process_wrapper: _spawnvp");
    return 1;
  }
  return exit_code;
#else
  execvp(exec_argv[0], exec_argv.data());
  std::perror("bootstrap_process_wrapper: execvp");
  return 1;
#endif
}
