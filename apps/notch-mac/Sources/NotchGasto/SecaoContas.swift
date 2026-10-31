import SwiftUI
import GastoCore

/// Cadastro das contas que entram em limites, gasto e retomadas.
///
/// A lista sai da chave `contas`. Sem a chave, começa em `ContaUso.padrao`.
/// Ligar ou desligar grava `ativo` (ausente = ligada, para o arquivo antigo).
/// O tipo só se escolhe numa conta nova, e só entre os tipos que o app já mede.
@MainActor
final class EstadoContas: ObservableObject {
    let modelo: ModeloAjustes
    @Published var contas: [ContaCadastro]
    @Published var erro: String?
    /// Ids abertos na lista. Fica aqui porque trocar o tipo de um rascunho muda o id.
    @Published var abertas: Set<String> = []
    var aoSalvar: () -> Void = {}

    init(modelo: ModeloAjustes) {
        self.modelo = modelo
        contas = ContasConfig.ler(modelo.dados)
    }

    func adicionar() {
        let rascunho = ContasConfig.rascunho(nas: contas)
        contas.append(rascunho)
        abertas.insert(rascunho.id)
        erro = nil
    }

    func podeRemover(_ c: ContaCadastro) -> Bool {
        ContasConfig.podeRemover(contas, c)
    }

    func remover(_ c: ContaCadastro) {
        guard let lista = ContasConfig.remover(c, de: contas) else { return }
        contas = lista
        abertas.remove(c.id)
        erro = nil
        if c.nova { return }
        gravar()
    }

    func alternarAberta(_ id: String) {
        if abertas.contains(id) { abertas.remove(id) } else { abertas.insert(id) }
    }

    func aplicarTipo(_ c: ContaCadastro, _ tipo: String) {
        guard let i = contas.firstIndex(where: { $0.id == c.id }) else { return }
        let antigo = contas[i].id
        let nova = ContasConfig.aplicarTipo(contas[i], tipo: tipo, nas: contas)
        contas[i] = nova
        if abertas.contains(antigo) {
            abertas.remove(antigo)
            abertas.insert(nova.id)
        }
    }

    func salvar(_ c: ContaCadastro) {
        guard let i = contas.firstIndex(where: { $0.id == c.id }) else { return }
        let copia = ContasConfig.normalizar(c)
        var lista = contas
        lista[i] = copia
        if let msg = ContasConfig.problema(copia, nas: lista) {
            erro = msg
            return
        }
        var gravada = copia
        gravada.nova = false
        contas[i] = gravada
        gravar()
    }

    func alternarAtivo(_ c: ContaCadastro, _ ativo: Bool) {
        guard let i = contas.firstIndex(where: { $0.id == c.id }) else { return }
        contas[i].ativo = ativo
        erro = nil
        if contas[i].nova { return }
        gravar()
    }

    private func gravar() {
        let rascunhos = contas.filter(\.nova)
        do {
            try modelo.definirContas(contas)
            var lidas = ContasConfig.ler(modelo.dados)
            let ids = Set(lidas.map(\.id))
            lidas.append(contentsOf: rascunhos.filter { !ids.contains($0.id) })
            contas = lidas
            erro = nil
            aoSalvar()
        } catch {
            erro = String(localized: "Não foi possível gravar: \(error.localizedDescription)")
        }
    }
}

struct SecaoContas: View {
    @StateObject private var estado: EstadoContas
    private var aoSalvar: () -> Void
    /// Embutido nos Ajustes: o título «Contas das lanes» vem do grupo, não de outro Section.
    var embutido = false

    init(modelo: ModeloAjustes, aoSalvar: @escaping () -> Void, embutido: Bool = false) {
        let estado = EstadoContas(modelo: modelo)
        estado.aoSalvar = aoSalvar
        _estado = StateObject(wrappedValue: estado)
        self.aoSalvar = aoSalvar
        self.embutido = embutido
    }

    var body: some View {
        Group {
            if embutido {
                conteudo
                rodape
            } else {
                Section {
                    conteudo
                } header: {
                    Text(String(localized: "Contas acompanhadas"))
                } footer: {
                    rodape
                }
            }
        }
        .onAppear { estado.aoSalvar = aoSalvar }
    }

    @ViewBuilder
    private var conteudo: some View {
        if let e = estado.erro {
            Text(e).font(.caption).foregroundStyle(.red)
        }
        ForEach($estado.contas) { $c in
            LinhaConta(conta: $c, estado: estado)
        }
        Button {
            estado.adicionar()
        } label: {
            Label(String(localized: "Adicionar conta"), systemImage: "plus")
        }
    }

    private var rodape: some View {
        Text(String(localized: "Estas contas entram em limites, gasto e retomadas. Só tipos que o app já mede. Provedor novo entra pelo catálogo agents.d, não por um nome livre."))
            .font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LinhaConta: View {
    @Binding var conta: ContaCadastro
    @ObservedObject var estado: EstadoContas

    private var aberto: Bool { estado.abertas.contains(conta.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Toggle(isOn: Binding(get: { conta.ativo },
                                     set: { estado.alternarAtivo(conta, $0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(conta.titulo).font(.body)
                        if conta.mostraSubtitulo {
                            Text(conta.subtitulo)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityHint(conta.subtitulo)
                Spacer()
                Button { estado.alternarAberta(conta.id) } label: {
                    Image(systemName: aberto ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Editar esta conta"))
                Button { estado.remover(conta) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Remover esta conta"))
                .disabled(!estado.podeRemover(conta))
            }
            if aberto {
                Group {
                    CampoConta(String(localized: "Rótulo"), texto: $conta.rotulo)
                    CampoConta(String(localized: "Nome"), texto: $conta.nome)
                    CampoConta(String(localized: "Sigla"), texto: $conta.sigla)
                    if conta.nova {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(localized: "Tipo")).font(.caption).foregroundStyle(.secondary)
                            Picker(String(localized: "Tipo"), selection: Binding(
                                get: { conta.tipo },
                                set: { estado.aplicarTipo(conta, $0) })) {
                                ForEach(ContasConfig.tiposNovos, id: \.self) { tipo in
                                    Text(ContasConfig.rotuloDoTipo(tipo)).tag(tipo)
                                }
                            }
                            .labelsHidden()
                            if let aviso = ContasConfig.avisoTipo(conta, nas: estado.contas) {
                                Text(aviso).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(localized: "Tipo")).font(.caption).foregroundStyle(.secondary)
                            Text(ContasConfig.rotuloDoTipo(conta.tipo))
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }
                    if conta.tipo == "copilot" {
                        CamposCopilot(conta: $conta, estado: estado)
                    }
                    Button(String(localized: "Salvar esta conta")) { estado.salvar(conta) }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CampoConta: View {
    let rotulo: String
    @Binding var texto: String

    init(_ rotulo: String, texto: Binding<String>) {
        self.rotulo = rotulo
        self._texto = texto
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(rotulo).font(.caption).foregroundStyle(.secondary)
            TextField(rotulo, text: $texto)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}

/// Usuário e cota vão para o config. O token vai para o Keychain e o campo esvazia.
private struct CamposCopilot: View {
    @Binding var conta: ContaCadastro
    @ObservedObject var estado: EstadoContas
    @State private var token = ""
    @State private var noCofre = false

    var body: some View {
        CampoConta(String(localized: "Usuário do GitHub"), texto: $conta.githubUsuario)
        CampoConta(String(localized: "Cota do mês (requisições premium)"), texto: $conta.cotaTexto)
        CampoConta(String(localized: "Arquivo do token (opcional)"), texto: $conta.arquivoToken)
        VStack(alignment: .leading, spacing: 4) {
            Text(noCofre
                 ? String(localized: "Token no Keychain")
                 : String(localized: "Sem token no Keychain"))
                .font(.caption).foregroundStyle(.secondary)
            SecureField(String(localized: "Token do GitHub"), text: $token)
                .font(.system(size: 11, design: .monospaced))
            Text(String(localized: "O token fica só no Keychain, nunca no arquivo de ajustes. Para um token fino, a permissão é Plan, leitura. O arquivo acima, se preenchido, é só o caminho."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(String(localized: "Salvar token")) { salvar() }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if noCofre {
                    Button(String(localized: "Apagar token")) { apagar() }
                }
            }
        }
        .onAppear { noCofre = TokenCopilot().ler() != nil }
    }

    private func salvar() {
        do {
            try TokenCopilot().salvar(token)
            token = ""
            noCofre = true
            estado.erro = nil
        } catch {
            estado.erro = String(localized: "Não foi possível salvar o token no Keychain: \(error.localizedDescription)")
        }
    }

    private func apagar() {
        TokenCopilot().apagar()
        noCofre = false
        token = ""
        estado.erro = nil
    }
}
