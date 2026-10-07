#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *const argv[]) {
    // Every caller starts the engine in CLI mode. Without --cli the engine would
    // launch its GUI, which can start the local HTTP API server (no
    // authentication, CORS "*"), so any other launch is refused before Java runs.
    if (argc < 2 || strcmp(argv[1], "--cli") != 0) {
        fprintf(stderr, "This helper runs only in CLI mode: the first argument must be --cli.\n");
        return 64;
    }

    uint32_t executablePathLength = PATH_MAX;
    char executablePath[PATH_MAX];

    if (_NSGetExecutablePath(executablePath, &executablePathLength) != 0) {
        return 127;
    }

    char *resolvedPath = realpath(executablePath, NULL);
    if (resolvedPath == NULL) {
        return 127;
    }

    char *helpersPath = strdup(resolvedPath);
    free(resolvedPath);
    if (helpersPath == NULL) {
        free(helpersPath);
        return 127;
    }

    char *helpersDirectory = dirname(helpersPath);
    char *contentsPath = helpersDirectory == NULL ? NULL : strdup(helpersDirectory);
    if (contentsPath == NULL) {
        free(helpersPath);
        return 127;
    }
    char *contentsDirectory = dirname(contentsPath);

    char *javaPath = NULL;
    char *classPath = NULL;
    if (contentsDirectory == NULL || asprintf(&javaPath, "%s/runtime/bin/java", contentsDirectory) == -1 ||
        asprintf(&classPath, "%s/app/autogram.jar:%s/app/dependency-jars/*", contentsDirectory, contentsDirectory) == -1) {
        free(helpersPath);
        free(contentsPath);
        free(javaPath);
        free(classPath);
        return 127;
    }

    char **javaArguments = calloc((size_t)argc + 10, sizeof(*javaArguments));
    if (javaArguments == NULL) {
        free(helpersPath);
        free(contentsPath);
        free(javaPath);
        free(classPath);
        return 127;
    }

    int index = 0;
    javaArguments[index++] = javaPath;
    javaArguments[index++] = "--add-exports=jdk.crypto.cryptoki/sun.security.pkcs11.wrapper=ALL-UNNAMED";
    javaArguments[index++] = "--add-opens=java.base/java.security=ALL-UNNAMED";
    javaArguments[index++] = "--add-opens=jdk.crypto.cryptoki/sun.security.pkcs11.wrapper=ALL-UNNAMED";
    javaArguments[index++] = "--add-opens=jdk.crypto.cryptoki/sun.security.pkcs11=ALL-UNNAMED";
    javaArguments[index++] = "--enable-native-access=ALL-UNNAMED";
    javaArguments[index++] = "-Djava.awt.headless=true";
    javaArguments[index++] = "-cp";
    javaArguments[index++] = classPath;
    javaArguments[index++] = "digital.slovensko.autogram.Main";
    for (int argumentIndex = 1; argumentIndex < argc; argumentIndex++) {
        javaArguments[index++] = argv[argumentIndex];
    }

    execv(javaPath, javaArguments);
    free(javaArguments);
    free(helpersPath);
    free(contentsPath);
    free(javaPath);
    free(classPath);
    return 127;
}
