import SwiftUI
import GastoCore

/// Cadastro de projetos que o dispatcher e o vigia enxergam.
///
/// É a tela que decide de onde as lanes trabalham: cada linha diz o projeto do
/// Linear, o repo, a pasta de worktrees, o comando de prova e o freio de caminho
/// protegido. Gravar aqui é o que faz o `dispatcher.py` passar a enxergar o
/// projeto — não há lista em código para atualizar junto.
///
/// Ler e escrever passa pelo `ModeloAjustes`, que mescla no config em uso sem
/// apagar as outras chaves.
@MainActor
final class EstadoProjetos: ObservableObject {
    let modelo: ModeloAjustes
    @Published var projetos: [ProjetoCadastro]
    @Published var erro: String?
    @Published var aviso: String?

    init(modelo: ModeloAjustes) {
        self.modelo = modelo
        projetos = ProjetosConfig.ler(modelo.dados)
    }

    private func gravar() {
        do {
            try modelo.definirProjetos(projetos)
            projetos = ProjetosConfig.ler(modelo.dados)
            erro = nil
            aviso = String(localized: "Salvo. O dispatcher passa a usar isso no próximo ciclo (até 60 s).")
        } catch {
            erro = String(localized: "Não foi possível gravar: \(error.localizedDescription)")
        }
    }

    func adicionar() {
        projetos.append(ProjetoCadastro(projetoID: "", nome: "", repo: "~/Developer/"))
        erro = nil
    }

    func remover(_ p: ProjetoCadastro) {
        projetos.removeAll { $0.projetoID == p.projetoID }
        gravar()
    }

    func mover(_ p: ProjetoCadastro, _ delta: Int) {
        guard let i = projetos.firstIndex(where: { $0.projetoID == p.projetoID }) else { return }
        let j = i + delta
        guard projetos.indices.contains(j) else { return }
        projetos.swapAt(i, j)
        gravar()
    }

    func salvar(_ p: ProjetoCadastro) {
        guard let i = projetos.firstIndex(where: { $0.projetoID == p.projetoID }) else { return }
        projetos[i] = p
        if let msg = p.problema() {
            erro = msg
            projetos[i].padrao = false
            return
        }
        gravar()
    }

    func alternarAtivo(_ p: ProjetoCadastro, _ ativo: Bool) {
        var copia = p
        copia.ativo = ativo
        salvar(copia)
    }

    func marcarPadrao(_ p: ProjetoCadastro) {
        for i in projetos.indices { projetos[i].padrao = projetos[i].projetoID == p.projetoID }
        gravar()
    }
}

struct SecaoProjetos: View {
    @ObservedObject var estado: EstadoProjetos

    var body: some View {
        Section {
            if let e = estado.erro {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            if let a = estado.aviso {
                Text(a).font(.caption).foregroundStyle(.secondary)
            }
            ForEach($estado.projetos) { $p in
                LinhaProjeto(projeto: $p, estado: estado)
            }
            Button {
                estado.adicionar()
            } label: {
                Label(String(localized: "Adicionar projeto"), systemImage: "plus")
            }
        } header: {
            Text(String(localized: "Projetos que o dispatcher enxerga"))
        } footer: {
            Text(String(localized: "O projeto marcado como padrão é o que as lanes trabalham neste ciclo. Sem ninguém marcado, vale o primeiro ativo da lista — a ordem da lista é a ordem de preferência. Desligar mantém o projeto listado aqui, sem o dispatcher assumir card nele."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct LinhaProjeto: View {
    @Binding var projeto: ProjetoCadastro
    @ObservedObject var estado: EstadoProjetos
    @State private var aberto = false

    private var podeSubir: Bool {
        (estado.projetos.firstIndex { $0.projetoID == projeto.projetoID } ?? 0) > 0
    }
    private var podeDescer: Bool {
        let i = estado.projetos.firstIndex { $0.projetoID == projeto.projetoID } ?? 0
        return i >= 0 && i < estado.projetos.count - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(get: { projeto.ativo },
                                     set: { estado.alternarAtivo(projeto, $0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(projeto.nome.isEmpty ? String(localized: "(sem nome)") : projeto.nome)
                            .font(.body)
                        Text(projeto.projetoID.isEmpty
                             ? String(localized: "id do Linear pendente")
                             : "\(projeto.repo) · \(String(projeto.projetoID.prefix(8)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { estado.marcarPadrao(projeto) } label: {
                    Image(systemName: projeto.padrao ? "largecircle.fill.circle" : "circle")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Tornar o projeto que as lanes trabalham"))
                .disabled(!projeto.padrao)
                Button { aberto.toggle() } label: {
                    Image(systemName: aberto ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                Button { estado.remover(projeto) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(estado.projetos.count <= 1)
            }
            if aberto {
                Group {
                    Campo("Nome", texto: $projeto.nome)
                    Campo("ID do projeto no Linear", texto: $projeto.projetoID)
                    Campo("Repo", texto: $projeto.repo)
                    Campo("Worktrees (vazio = repo-worktrees)", texto: $projeto.worktrees)
                    Campo("Prova (usa {suite})", texto: $projeto.prova)
                    Campo("Tentativas da prova", texto: Binding(
                        get: { "\(projeto.provaTentativas)" },
                        set: { projeto.provaTentativas = Int($0) ?? 1 }))
                    Campo("Caminhos protegidos (um por linha)", multilinha: true,
                          texto: Binding(
                            get: { projeto.protegidos.joined(separator: "\n") },
                            set: { projeto.protegidos = $0.split(separator: "\n")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty } }))
                    HStack {
                        Button(String(localized: "Salvar este projeto")) { estado.salvar(projeto) }
                        Button(String(localized: "Subir")) { estado.mover(projeto, -1) }
                            .disabled(!podeSubir)
                        Button(String(localized: "Descer")) { estado.mover(projeto, 1) }
                            .disabled(!podeDescer)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct Campo: View {
    let rotulo: String
    var multilinha = false
    @Binding var texto: String

    init(_ rotulo: String, multilinha: Bool = false, texto: Binding<String>) {
        self.rotulo = rotulo
        self.multilinha = multilinha
        self._texto = texto
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(rotulo).font(.caption).foregroundStyle(.secondary)
            if multilinha {
                TextEditor(text: $texto)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 70)
            } else {
                TextField(rotulo, text: $texto)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
    }
}