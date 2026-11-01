// Lançador compilado dos agentes do TuttiDash (SMAppService).
// Uso: tuttidash-agente <dispatcher|vigia|chave>
// Executa o script em Contents/Resources/controle do mesmo .app.
// Não lê nem executa cópia em ~/.transcentia.
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <stdint.h>
#include <mach-o/dyld.h>
#endif

static int caminho_executavel(char *buf, size_t n) {
#ifdef __APPLE__
    uint32_t sz = (uint32_t)n;
    if (_NSGetExecutablePath(buf, &sz) != 0) return -1;
    return 0;
#else
    ssize_t r = readlink("/proc/self/exe", buf, n - 1);
    if (r < 0) return -1;
    buf[r] = '\0';
    return 0;
#endif
}

static void garantir_pasta(const char *caminho) {
    char buf[1024];
    snprintf(buf, sizeof buf, "%s", caminho);
    for (char *p = buf + 1; *p; ++p) {
        if (*p != '/') continue;
        *p = '\0';
        (void)mkdir(buf, 0755);
        *p = '/';
    }
    (void)mkdir(buf, 0755);
}

static int recusa(const char *caminho) {
    return strstr(caminho, ".transcentia") != NULL || strstr(caminho, "..") != NULL;
}

/* tuttidash-agente está em TuttiDash.app/Contents/MacOS/.
   O script fica em TuttiDash.app/Contents/Resources/controle/<rel>. */
static int script_do_bundle(const char *rel, char *saida, size_t n) {
    char bruto[PATH_MAX];
    char real[PATH_MAX];
    char dir1[PATH_MAX];
    char dir2[PATH_MAX];
    if (recusa(rel)) return -1;
    if (caminho_executavel(bruto, sizeof bruto) != 0) return -1;
    if (!realpath(bruto, real)) return -1;
    if (recusa(real)) return -1;
    snprintf(dir1, sizeof dir1, "%s", real);
    char *macos = dirname(dir1);                 /* .../Contents/MacOS */
    snprintf(dir2, sizeof dir2, "%s", macos);
    char *contents = dirname(dir2);              /* .../Contents */
    if (snprintf(saida, n, "%s/Resources/controle/%s", contents, rel) >= (int)n) return -1;
    if (recusa(saida)) return -1;
    if (access(saida, R_OK) != 0) return -1;
    return 0;
}

/* Resources do próprio .app. O dispatcher e o catálogo leem settings, MCP e
   agents.d daqui (FRA-614), não de ~/.transcentia. Não mexe em enabled nem PAUSE. */
static void definir_recursos(void) {
    char exe[4096];
    uint32_t n = (uint32_t)sizeof exe;
    if (_NSGetExecutablePath(exe, &n) != 0) return;
    char real[4096];
    if (!realpath(exe, real)) return;
    char *marca = strstr(real, ".app/Contents/MacOS/");
    if (!marca) return;
    size_t prefixo = (size_t)(marca - real) + strlen(".app/Contents");
    if (prefixo + strlen("/Resources") >= sizeof real) return;
    char recursos[4096];
    memcpy(recursos, real, prefixo);
    memcpy(recursos + prefixo, "/Resources", strlen("/Resources") + 1);
    if (strstr(recursos, "/.transcentia/")) return;
    setenv("TUTTIDASH_RECURSOS", recursos, 1);
}

int main(int argc, char **argv) {
    const char *home = getenv("HOME");
    if (!home || argc < 2) {
        fprintf(stderr, "uso: tuttidash-agente <dispatcher|vigia|chave>\n");
        return 64;
    }
    const char *rel = NULL, *log = NULL, *extra = NULL;
    if (!strcmp(argv[1], "dispatcher")) {
        rel = "lanes/dispatcher.py";
        log = "lanes-dispatcher.launchd.log";
        extra = "--real";
    } else if (!strcmp(argv[1], "vigia")) {
        rel = "bots/watch.py";
        log = "bots-watch.launchd.log";
    } else if (!strcmp(argv[1], "chave")) {
        rel = "tools/bots-chave";
        log = "bots-chave.launchd.log";
    } else {
        fprintf(stderr, "agente desconhecido: %s\n", argv[1]);
        return 64;
    }
    char alvo[PATH_MAX];
    if (script_do_bundle(rel, alvo, sizeof alvo) != 0) {
        fprintf(stderr, "script do bundle ausente ou recusado: %s\n", rel);
        return 70;
    }
    char dir[1024], arq[1200];
    snprintf(dir, sizeof dir, "%s/Library/Logs/TranscentIA", home);
    garantir_pasta(dir);
    snprintf(arq, sizeof arq, "%s/%s", dir, log);
    /* O_NOFOLLOW: um symlink no lugar do log não desvia a saída. 0600: só o dono lê. */
    int fd = open(arq, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
    if (fd >= 0) { fchmod(fd, 0600); dup2(fd, 1); dup2(fd, 2); close(fd); }
    definir_recursos();
    char *args[] = {"/usr/bin/python3", alvo, (char *)extra, NULL};
    execv("/usr/bin/python3", args);
    perror("execv");
    return 70;
}
