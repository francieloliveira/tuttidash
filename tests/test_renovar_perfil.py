"""tools/renovar-perfil.sh: renova o provisioning profile de macOS com o login do Xcode."""
import subprocess
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
SCRIPT = RAIZ / "tools" / "renovar-perfil.sh"


class RenovarPerfil(unittest.TestCase):
    def setUp(self):
        self.texto = SCRIPT.read_text(encoding="utf-8")

    def test_sintaxe_e_argumento_desconhecido(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)
        r = subprocess.run(["bash", str(SCRIPT), "--outro"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 64)
        self.assertIn("uso:", r.stderr)

    def test_usa_o_mesmo_bundle_id_e_entitlements_do_app(self):
        self.assertIn('ID="app.tuttidash.mac"', self.texto)
        self.assertIn('EQUIPE="3QA76CY27W"', self.texto)
        self.assertIn("Resources/TuttiDash.entitlements", self.texto)
        self.assertIn("CODE_SIGN_STYLE: Automatic", self.texto)

    def test_gera_pelo_login_do_xcode_e_registra_o_mac(self):
        self.assertIn("-allowProvisioningUpdates", self.texto)
        self.assertIn("-allowProvisioningDeviceRegistration", self.texto)
        self.assertIn('-destination "platform=macOS', self.texto)

    def test_grava_so_profile_de_macos_do_app_no_privado(self):
        # O build.sh lê este caminho; o Privado/ fica fora do git.
        self.assertIn("Privado/TuttiDash.provisionprofile", self.texto)
        self.assertIn('install -m 600 "$PERFIL" "$DESTINO"', self.texto)
        self.assertIn('"OSX"', self.texto)
        self.assertIn("Entitlements.com", self.texto)
        self.assertIn("Privado/", (RAIZ / ".gitignore").read_text(encoding="utf-8"))

    def test_app_temporario_sai_do_launchservices(self):
        # O app temporário tem o bundle id do TuttiDash: sem isto, `open` pode achá-lo.
        self.assertIn('"$LSREGISTER" -u "$APP_TMP"', self.texto)
        self.assertIn("trap limpar EXIT", self.texto)


if __name__ == "__main__":
    unittest.main()
