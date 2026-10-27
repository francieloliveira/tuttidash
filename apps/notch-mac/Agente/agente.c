// Lançador compilado dos agentes do TuttiDash (SMAppService). Uso: tuttidash-agente <dispatcher|vigia|chave>
// Só faz exec do script atual em ~/.transcentia; não lê nem grava `enabled` ou PAUSE.
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *home = getenv("HOME");
    if (!home || argc < 2) { fprintf(stderr, "uso: tuttidash-agente <dispatcher|vigia|chave>\n"); return 64; }
    const char *script = NULL, *log = NULL, *extra = NULL;
    if (!strcmp(argv[1], "dispatcher")) { script = ".transcentia/lanes/dispatcher.py"; log = "lanes-dispatcher.launchd.log"; extra = "--real"; }
    else if (!strcmp(argv[1], "vigia")) { script = ".transcentia/bots/watch.py"; log = "bots-watch.launchd.log"; }
    else if (!strcmp(argv[1], "chave")) { script = ".transcentia/tools/bots-chave"; log = "bots-chave.launchd.log"; }
    else { fprintf(stderr, "agente desconhecido: %s\n", argv[1]); return 64; }
    char dir[1024], arq[1200], alvo[1200];
    snprintf(dir, sizeof dir, "%s/Library/Logs/TranscentIA", home);
    mkdir(dir, 0755);
    snprintf(arq, sizeof arq, "%s/%s", dir, log);
    int fd = open(arq, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
    snprintf(alvo, sizeof alvo, "%s/%s", home, script);
    char *args[] = { "/usr/bin/python3", alvo, (char *)extra, NULL };
    execv("/usr/bin/python3", args);
    perror("execv");
    return 70;
}
