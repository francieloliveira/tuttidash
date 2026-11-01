// Lançador compilado dos agentes do TuttiDash (SMAppService).
// Uso: tuttidash-agente <dispatcher|vigia|chave>
// Executa o script em Contents/Resources/controle do mesmo .app.
// Não lê nem executa cópia em ~/.transcentia.
//
// FRA-616: antes do exec, confere a âncora fora do bundle
// (/private/var/db/tuttidash/controle.sha256 no Mac, dono root) e a
// designated requirement Apple Development da equipe 3QA76CY27W.
// Não usa CDHash. Divergência sai 77 e não chega no python.
#include <dirent.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

#define MAX_ENTRADAS 64
#define MAX_REL 240
#define LIMITE_ARQUIVO (8 * 1024 * 1024)
#define LIMITE_MANIFESTO (32 * 1024)

static const char MAGIA[] = "tuttidash-controle-v1";
static const char EQUIPE[] = "3QA76CY27W";
static const char REQUISITO[] =
    "anchor apple generic and certificate leaf[subject.OU] = \"3QA76CY27W\" "
    "and certificate leaf[field.1.2.840.113635.100.6.1.12]";
#ifdef __APPLE__
static const char ANCORA_SISTEMA[] = "/private/var/db/tuttidash/controle.sha256";
#else
static const char ANCORA_SISTEMA[] = "/var/db/tuttidash/controle.sha256";
#endif

typedef struct {
    uint32_t h[8];
    uint64_t nbits;
    unsigned char buf[64];
    size_t n;
} Sha256;

typedef struct {
    char rel[MAX_REL];
    char hex[65];
} Entrada;

static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

static uint32_t rotr(uint32_t x, uint32_t n) { return (x >> n) | (x << (32 - n)); }

static void sha256_bloco(Sha256 *s, const unsigned char *p) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16) | ((uint32_t)p[4 * i + 2] << 8) |
               (uint32_t)p[4 * i + 3];
    }
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = s->h[0], b = s->h[1], c = s->h[2], d = s->h[3];
    uint32_t e = s->h[4], f = s->h[5], g = s->h[6], h = s->h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t t1 = h + s1 + ch + K256[i] + w[i];
        uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = s0 + maj;
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }
    s->h[0] += a;
    s->h[1] += b;
    s->h[2] += c;
    s->h[3] += d;
    s->h[4] += e;
    s->h[5] += f;
    s->h[6] += g;
    s->h[7] += h;
}

static void sha256_init(Sha256 *s) {
    s->h[0] = 0x6a09e667;
    s->h[1] = 0xbb67ae85;
    s->h[2] = 0x3c6ef372;
    s->h[3] = 0xa54ff53a;
    s->h[4] = 0x510e527f;
    s->h[5] = 0x9b05688c;
    s->h[6] = 0x1f83d9ab;
    s->h[7] = 0x5be0cd19;
    s->nbits = 0;
    s->n = 0;
}

static int sha256_update(Sha256 *s, const unsigned char *p, size_t n) {
    if (n > (UINT64_MAX / 8) || s->nbits > UINT64_MAX - (uint64_t)n * 8) return -1;
    s->nbits += (uint64_t)n * 8;
    while (n > 0) {
        size_t cabe = 64 - s->n;
        size_t pegar = n < cabe ? n : cabe;
        memcpy(s->buf + s->n, p, pegar);
        s->n += pegar;
        p += pegar;
        n -= pegar;
        if (s->n == 64) {
            sha256_bloco(s, s->buf);
            s->n = 0;
        }
    }
    return 0;
}

static int sha256_final(Sha256 *s, char hex[65]) {
    unsigned char bloco[64];
    uint64_t bits = s->nbits;
    s->buf[s->n++] = 0x80;
    if (s->n > 56) {
        while (s->n < 64) s->buf[s->n++] = 0;
        sha256_bloco(s, s->buf);
        s->n = 0;
    }
    while (s->n < 56) s->buf[s->n++] = 0;
    for (int i = 0; i < 8; i++) s->buf[63 - i] = (unsigned char)((bits >> (8 * i)) & 0xff);
    sha256_bloco(s, s->buf);
    for (int i = 0; i < 8; i++) {
        bloco[4 * i] = (unsigned char)(s->h[i] >> 24);
        bloco[4 * i + 1] = (unsigned char)(s->h[i] >> 16);
        bloco[4 * i + 2] = (unsigned char)(s->h[i] >> 8);
        bloco[4 * i + 3] = (unsigned char)s->h[i];
    }
    for (int i = 0; i < 32; i++) snprintf(hex + (size_t)i * 2, 3, "%02x", bloco[i]);
    hex[64] = '\0';
    return 0;
}

static int sha256_arquivo(const char *caminho, char hex[65]) {
    struct stat st;
    if (lstat(caminho, &st) != 0 || !S_ISREG(st.st_mode)) return -1;
    if (st.st_size < 0 || st.st_size > LIMITE_ARQUIVO) return -1;
    int fd = open(caminho, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return -1;
    struct stat st2;
    if (fstat(fd, &st2) != 0 || !S_ISREG(st2.st_mode) || st2.st_size != st.st_size) {
        close(fd);
        return -1;
    }
    Sha256 s;
    sha256_init(&s);
    unsigned char buf[8192];
    size_t total = 0;
    for (;;) {
        ssize_t r = read(fd, buf, sizeof buf);
        if (r < 0) {
            close(fd);
            return -1;
        }
        if (r == 0) break;
        total += (size_t)r;
        if (total > LIMITE_ARQUIVO || sha256_update(&s, buf, (size_t)r) != 0) {
            close(fd);
            return -1;
        }
    }
    close(fd);
    if ((off_t)total != st.st_size) return -1;
    return sha256_final(&s, hex);
}

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

static int sob(const char *caminho, const char *raiz) {
    size_t n;
    if (!raiz || !raiz[0] || !caminho) return 0;
    n = strlen(raiz);
    if (strncmp(caminho, raiz, n) != 0) return 0;
    return caminho[n] == '\0' || caminho[n] == '/';
}

/* tuttidash-agente está em TuttiDash.app/Contents/MacOS/.
   O controle fica em TuttiDash.app/Contents/Resources/controle. */
static int diretorio_controle(char *saida, size_t n) {
    char bruto[PATH_MAX];
    char real[PATH_MAX];
    char dir1[PATH_MAX];
    char dir2[PATH_MAX];
    struct stat st;
    if (caminho_executavel(bruto, sizeof bruto) != 0) return -1;
    if (!realpath(bruto, real)) return -1;
    if (recusa(real)) return -1;
    snprintf(dir1, sizeof dir1, "%s", real);
    char *macos = dirname(dir1);
    snprintf(dir2, sizeof dir2, "%s", macos);
    char *contents = dirname(dir2);
    if (snprintf(saida, n, "%s/Resources/controle", contents) >= (int)n) return -1;
    if (recusa(saida)) return -1;
    if (lstat(saida, &st) != 0 || !S_ISDIR(st.st_mode)) return -1;
    return 0;
}

static int script_do_bundle(const char *rel, char *saida, size_t n) {
    char controle[PATH_MAX];
    struct stat st;
    if (recusa(rel)) return -1;
    if (diretorio_controle(controle, sizeof controle) != 0) return -1;
    if (snprintf(saida, n, "%s/%s", controle, rel) >= (int)n) return -1;
    if (recusa(saida)) return -1;
    if (lstat(saida, &st) != 0 || !S_ISREG(st.st_mode)) return -1;
    if (access(saida, R_OK) != 0) return -1;
    return 0;
}

static int componente_seguro(const char *path, int precisa_dir, uid_t dono) {
    struct stat st;
    if (lstat(path, &st) != 0) return 0;
    if (S_ISLNK(st.st_mode)) return 0;
    if (precisa_dir && !S_ISDIR(st.st_mode)) return 0;
    if (!precisa_dir && !S_ISREG(st.st_mode)) return 0;
    if (st.st_uid != dono) return 0;
    if (st.st_mode & (S_IWGRP | S_IWOTH)) return 0;
    return 1;
}

/* Produção ignora o ambiente: a âncora é o caminho fixo, dono root.
   O binário de teste (TUTTIDASH_INTEGRIDADE_TESTE) lê o caminho do
   ambiente para poder rodar sem root. O build.sh não passa essa flag. */
static const char *caminho_ancora(void) {
#ifdef TUTTIDASH_INTEGRIDADE_TESTE
    const char *e = getenv("TUTTIDASH_INTEGRIDADE_ARQUIVO");
    if (!e || !e[0] || e[0] != '/' || strlen(e) >= PATH_MAX) return NULL;
    if (strchr(e, '\n') || strchr(e, '\r') || strstr(e, "..")) return NULL;
    return e;
#else
    return ANCORA_SISTEMA;
#endif
}

static int ancora_fora_do_agente(const char *caminho, const char *home, const char *controle) {
    if (!caminho || caminho[0] != '/') return 0;
    if (recusa(caminho)) return 0;
    if (strstr(caminho, "/Contents/")) return 0;
    if (sob(caminho, home) || sob(caminho, controle)) return 0;
#ifdef TUTTIDASH_INTEGRIDADE_TESTE
    return 1;
#else
    return strcmp(caminho, ANCORA_SISTEMA) == 0;
#endif
}

static int diretorio_ancora_ok(const char *arquivo, uid_t dono) {
#ifdef TUTTIDASH_INTEGRIDADE_TESTE
    char dir[PATH_MAX];
    char *slash;
    snprintf(dir, sizeof dir, "%s", arquivo);
    slash = strrchr(dir, '/');
    if (!slash || slash == dir) return 0;
    *slash = '\0';
    return componente_seguro(dir, 1, dono);
#else
    (void)arquivo;
    (void)dono;
#ifdef __APPLE__
    return componente_seguro("/private", 1, 0) && componente_seguro("/private/var", 1, 0) &&
           componente_seguro("/private/var/db", 1, 0) && componente_seguro("/private/var/db/tuttidash", 1, 0);
#else
    return componente_seguro("/var", 1, 0) && componente_seguro("/var/db", 1, 0) &&
           componente_seguro("/var/db/tuttidash", 1, 0);
#endif
#endif
}

static int hex64(const char *s) {
    for (int i = 0; i < 64; i++) {
        char c = s[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return 0;
    }
    return s[64] == '\0';
}

static int rel_ok(const char *rel) {
    const char *p;
    int comp = 0;
    if (!rel || !rel[0] || rel[0] == '/' || strlen(rel) >= MAX_REL) return 0;
    if (strstr(rel, "..") || strstr(rel, "//") || strstr(rel, ".transcentia")) return 0;
    for (p = rel; *p; ++p) {
        char c = *p;
        if (c == '/') {
            if (comp == 0) return 0;
            comp = 0;
            continue;
        }
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' ||
              c == '.'))
            return 0;
        comp++;
    }
    return comp > 0;
}

static int parse_manifesto(char *texto, Entrada *ents, int *n) {
    char *linha;
    char *salva = NULL;
    int i = 0;
    char *cursor = texto;
    linha = strtok_r(cursor, "\n", &salva);
    if (!linha || strcmp(linha, MAGIA) != 0) return -1;
    linha = strtok_r(NULL, "\n", &salva);
    if (!linha || strncmp(linha, "team ", 5) != 0 || strcmp(linha + 5, EQUIPE) != 0) return -1;
    while ((linha = strtok_r(NULL, "\n", &salva)) != NULL) {
        char *sp;
        if (linha[0] == '\0') continue;
        if (i >= MAX_ENTRADAS) return -1;
        if (strlen(linha) < 66) return -1;
        sp = strchr(linha, ' ');
        if (!sp || sp != linha + 64 || strchr(sp + 1, ' ')) return -1;
        *sp = '\0';
        if (!hex64(linha) || !rel_ok(sp + 1)) return -1;
        snprintf(ents[i].hex, sizeof ents[i].hex, "%s", linha);
        snprintf(ents[i].rel, sizeof ents[i].rel, "%s", sp + 1);
        if (i > 0 && strcmp(ents[i - 1].rel, ents[i].rel) >= 0) return -1;
        i++;
    }
    if (i == 0) return -1;
    *n = i;
    return 0;
}

static int ler_ancora(const char *caminho, char *buf, size_t n) {
    struct stat st;
    int fd;
    size_t off = 0;
    if (lstat(caminho, &st) != 0 || !S_ISREG(st.st_mode)) return -1;
    if (st.st_size <= 0 || st.st_size >= (off_t)n) return -1;
    fd = open(caminho, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return -1;
    while (off + 1 < n) {
        ssize_t r = read(fd, buf + off, n - 1 - off);
        if (r < 0) {
            close(fd);
            return -1;
        }
        if (r == 0) break;
        off += (size_t)r;
    }
    close(fd);
    buf[off] = '\0';
    if (memchr(buf, '\0', off) != NULL && strlen(buf) != off) return -1;
    if (strchr(buf, '\r')) return -1;
    return 0;
}

static int ignorar_nome(const char *nome) {
    size_t n;
    if (!nome || nome[0] == '\0' || nome[0] == '.') return 1;
    if (strcmp(nome, "__pycache__") == 0) return 1;
    n = strlen(nome);
    return n > 4 && strcmp(nome + n - 4, ".pyc") == 0;
}

static int nome_ok(const char *nome) {
    const char *p;
    if (!nome || !nome[0] || strcmp(nome, ".") == 0 || strcmp(nome, "..") == 0) return 0;
    for (p = nome; *p; ++p) {
        char c = *p;
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' ||
              c == '.'))
            return 0;
    }
    return strstr(nome, "..") == NULL;
}

static int listar(const char *base, const char *rel, char paths[][MAX_REL], int *n, int max, int profundidade) {
    char dir[PATH_MAX];
    DIR *d;
    struct dirent *ent;
    if (profundidade > 8) return -1;
    if (rel[0]) {
        if (snprintf(dir, sizeof dir, "%s/%s", base, rel) >= (int)sizeof dir) return -1;
    } else {
        snprintf(dir, sizeof dir, "%s", base);
    }
    d = opendir(dir);
    if (!d) return -1;
    while ((ent = readdir(d)) != NULL) {
        char filho[MAX_REL];
        char cheio[PATH_MAX];
        struct stat st;
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
        if (ignorar_nome(ent->d_name)) continue;
        if (!nome_ok(ent->d_name)) {
            closedir(d);
            return -1;
        }
        if (rel[0]) {
            if (snprintf(filho, sizeof filho, "%s/%s", rel, ent->d_name) >= (int)sizeof filho) {
                closedir(d);
                return -1;
            }
        } else {
            snprintf(filho, sizeof filho, "%s", ent->d_name);
        }
        if (snprintf(cheio, sizeof cheio, "%s/%s", base, filho) >= (int)sizeof cheio) {
            closedir(d);
            return -1;
        }
        if (lstat(cheio, &st) != 0 || S_ISLNK(st.st_mode)) {
            closedir(d);
            return -1;
        }
        if (S_ISDIR(st.st_mode)) {
            if (listar(base, filho, paths, n, max, profundidade + 1) != 0) {
                closedir(d);
                return -1;
            }
            continue;
        }
        if (!S_ISREG(st.st_mode)) {
            closedir(d);
            return -1;
        }
        if (*n >= max) {
            closedir(d);
            return -1;
        }
        snprintf(paths[*n], MAX_REL, "%s", filho);
        (*n)++;
    }
    closedir(d);
    return 0;
}

static int cmp_path(const void *a, const void *b) { return strcmp((const char *)a, (const char *)b); }

static int arvore_confere(const char *controle, Entrada *ents, int nent) {
    char paths[MAX_ENTRADAS][MAX_REL];
    int n = 0;
    if (listar(controle, "", paths, &n, MAX_ENTRADAS, 0) != 0) return -1;
    qsort(paths, (size_t)n, MAX_REL, cmp_path);
    if (n != nent) return -1;
    for (int i = 0; i < n; i++) {
        char cheio[PATH_MAX];
        char hex[65];
        if (strcmp(paths[i], ents[i].rel) != 0) return -1;
        if (snprintf(cheio, sizeof cheio, "%s/%s", controle, ents[i].rel) >= (int)sizeof cheio) return -1;
        if (!sob(cheio, controle)) return -1;
        if (sha256_arquivo(cheio, hex) != 0) return -1;
        if (strcmp(hex, ents[i].hex) != 0) return -1;
    }
    return 0;
}

#ifndef TUTTIDASH_PULAR_ASSINATURA
static int ler_saida(const char *bin, char *const argv[], char *buf, size_t n, int *codigo) {
    int fds[2];
    pid_t pid;
    size_t off = 0;
    int st = 0;
    if (pipe(fds) != 0) return -1;
    pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    if (pid == 0) {
        dup2(fds[1], 1);
        dup2(fds[1], 2);
        close(fds[0]);
        close(fds[1]);
        execv(bin, argv);
        _exit(127);
    }
    close(fds[1]);
    for (;;) {
        char tmp[512];
        ssize_t r = read(fds[0], tmp, sizeof tmp);
        if (r < 0) {
            close(fds[0]);
            waitpid(pid, &st, 0);
            return -1;
        }
        if (r == 0) break;
        if (off + 1 < n) {
            size_t cabe = n - 1 - off;
            size_t pegar = (size_t)r < cabe ? (size_t)r : cabe;
            memcpy(buf + off, tmp, pegar);
            off += pegar;
        }
    }
    buf[off] = '\0';
    close(fds[0]);
    if (waitpid(pid, &st, 0) < 0) return -1;
    *codigo = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    return 0;
}

static int assinatura_ok(const char *app) {
    char saida[8192];
    int codigo = -1;
    char *argv_d[] = {"codesign", "-d", "-r-", (char *)app, NULL};
    /* `-R` sem `=` lê o argumento como caminho de arquivo; com `=` é o requisito em texto. */
    char requisito[sizeof REQUISITO + 1];
    char *argv_v[] = {"codesign", "--verify", "--strict", "-R", requisito, (char *)app, NULL};
    const char *marca;
    const char *fim;
    if (access("/usr/bin/codesign", X_OK) != 0) return 0;
    snprintf(requisito, sizeof requisito, "=%s", REQUISITO);
    if (ler_saida("/usr/bin/codesign", argv_d, saida, sizeof saida, &codigo) != 0 || codigo != 0) return 0;
    marca = strstr(saida, "designated =>");
    if (!marca) return 0;
    fim = strchr(marca, '\n');
    if (fim) {
        /* compara só a linha do designated requirement */
        char linha[4096];
        size_t len = (size_t)(fim - marca);
        if (len >= sizeof linha) return 0;
        memcpy(linha, marca, len);
        linha[len] = '\0';
        if (!strstr(linha, EQUIPE) || !strstr(linha, "anchor apple generic") || !strstr(linha, "certificate leaf"))
            return 0;
        if (strstr(linha, "cdhash") && !strstr(linha, "certificate leaf")) return 0;
    } else {
        return 0;
    }
    if (ler_saida("/usr/bin/codesign", argv_v, saida, sizeof saida, &codigo) != 0 || codigo != 0) return 0;
    return 1;
}
#else
static int assinatura_ok(const char *app) {
    (void)app;
    (void)REQUISITO;
    return 1;
}
#endif

static int caminho_app(char *saida, size_t n) {
    char bruto[PATH_MAX];
    char real[PATH_MAX];
    const char *marca;
    size_t len;
    if (caminho_executavel(bruto, sizeof bruto) != 0) return -1;
    if (!realpath(bruto, real)) return -1;
    marca = strstr(real, "/Contents/MacOS/");
    if (!marca || marca == real) return -1;
    len = (size_t)(marca - real);
    if (len + 1 > n) return -1;
    memcpy(saida, real, len);
    saida[len] = '\0';
    if (recusa(saida)) return -1;
    return 0;
}

/* Devolve NULL se pode executar. Senão, o código curto da divergência. */
static const char *verificar(const char *home) {
    char controle[PATH_MAX];
    char texto[LIMITE_MANIFESTO];
    char copia[LIMITE_MANIFESTO];
    Entrada ents[MAX_ENTRADAS];
    int nent = 0;
    const char *ancora;
    uid_t dono;
    struct stat st;
    char app[PATH_MAX];
    if (diretorio_controle(controle, sizeof controle) != 0) return "arvore";
    ancora = caminho_ancora();
    if (!ancora_fora_do_agente(ancora, home, controle)) return "alcance";
#ifdef TUTTIDASH_INTEGRIDADE_TESTE
    dono = geteuid();
#else
    dono = 0;
#endif
    if (lstat(ancora, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != dono || (st.st_mode & (S_IWGRP | S_IWOTH)))
        return "ancora";
    if (!diretorio_ancora_ok(ancora, dono)) return "ancora";
    if (ler_ancora(ancora, texto, sizeof texto) != 0) return "ancora";
    memcpy(copia, texto, sizeof copia);
    if (parse_manifesto(copia, ents, &nent) != 0) return "manifesto";
    if (arvore_confere(controle, ents, nent) != 0) return "hash";
    if (caminho_app(app, sizeof app) != 0) return "assinatura";
    if (!assinatura_ok(app)) return "assinatura";
    return NULL;
}

static void registrar_falha(const char *home, const char *log, const char *linha) {
    char dir[1024], arq[1200];
    size_t len;
    int fd;
    if (!log || strchr(log, '/') || strstr(log, "..")) return;
    snprintf(dir, sizeof dir, "%s/Library/Logs/TranscentIA", home);
    garantir_pasta(dir);
    snprintf(arq, sizeof arq, "%s/%s", dir, log);
    fd = open(arq, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    len = strlen(linha);
    if (write(fd, linha, len) < 0) {
        close(fd);
        return;
    }
    if (write(fd, "\n", 1) < 0) {
        close(fd);
        return;
    }
    close(fd);
}

static int falha_integridade(const char *home, const char *log, const char *codigo) {
    char linha[512];
    if (strcmp(codigo, "ancora") == 0)
        snprintf(linha, sizeof linha, "integridade: divergencia: ancora %s", ANCORA_SISTEMA);
    else if (strcmp(codigo, "assinatura") == 0)
        snprintf(linha, sizeof linha, "integridade: divergencia: assinatura %s", EQUIPE);
    else
        snprintf(linha, sizeof linha, "integridade: divergencia: %s", codigo);
    fprintf(stderr, "%s\n", linha);
    registrar_falha(home, log, linha);
    return 77;
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
    const char *home;
    const char *rel = NULL, *log = NULL, *extra = NULL;
    const char *motivo;
    char alvo[PATH_MAX];
    char dir[1024], arq[1200];
    int fd;
#ifdef TUTTIDASH_INTEGRIDADE_TESTE
    if (argc == 3 && strcmp(argv[1], "--sha256") == 0) {
        char hex[65];
        if (sha256_arquivo(argv[2], hex) != 0) return 70;
        printf("%s\n", hex);
        return 0;
    }
#endif
    home = getenv("HOME");
    if (!home || argc < 2) {
        fprintf(stderr, "uso: tuttidash-agente <dispatcher|vigia|chave>\n");
        return 64;
    }
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
    if (script_do_bundle(rel, alvo, sizeof alvo) != 0) {
        fprintf(stderr, "script do bundle ausente ou recusado: %s\n", rel);
        return 70;
    }
    motivo = verificar(home);
    if (motivo) return falha_integridade(home, log, motivo);
    snprintf(dir, sizeof dir, "%s/Library/Logs/TranscentIA", home);
    garantir_pasta(dir);
    snprintf(arq, sizeof arq, "%s/%s", dir, log);
    /* O_NOFOLLOW: um symlink no lugar do log não desvia a saída. 0600: só o dono lê. */
    fd = open(arq, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
    if (fd >= 0) {
        fchmod(fd, 0600);
        dup2(fd, 1);
        dup2(fd, 2);
        close(fd);
    }
    definir_recursos();
    char *args[] = {"/usr/bin/python3", alvo, (char *)extra, NULL};
    execv("/usr/bin/python3", args);
    perror("execv");
    return 70;
}
