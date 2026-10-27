import json
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import config as C


class Config(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_padrao_mac(self):
        r = C.resolve({}, env={}, platform="darwin", home=self.home)
        v = r["valores"]
        self.assertEqual(v["logs_dir"], self.home / "Library" / "Logs" / "TranscentIA" / "lanes")
        self.assertEqual(v["state_dir"], self.home / ".transcentia" / "lanes")
        self.assertEqual(v["ledger"], self.home / ".transcentia" / "tools" / "ledger.jsonl")
        self.assertIsNone(v["teto_semanal_usd"])
        self.assertEqual(v["aviso_pct"], 80.0)
        self.assertTrue(all(o == "padrão" for o in r["origem"].values()))

    def test_padrao_windows(self):
        env = {"APPDATA": str(self.home / "Roaming"), "LOCALAPPDATA": str(self.home / "Local")}
        v = C.resolve({}, env=env, platform="win32", home=self.home)["valores"]
        self.assertEqual(v["logs_dir"], self.home / "Local" / "TranscentIA" / "Logs" / "lanes")
        self.assertEqual(v["ledger"], self.home / "Roaming" / "tuttidash" / "ledger.jsonl")

    def test_prioridade_flag_env_config(self):
        cfg = self.home / "cfg.json"
        cfg.write_text(json.dumps({"logs_dir": "~/do-config", "state_dir": "~/estado-config",
                                   "teto_semanal_usd": 50}), encoding="utf-8")
        env = {C.ENV_CONFIG: str(cfg), C.ENV["state_dir"]: str(self.home / "estado-env")}
        r = C.resolve({"logs_dir": str(self.home / "da-flag")}, env=env, platform="darwin", home=self.home)
        v, o = r["valores"], r["origem"]
        self.assertEqual(v["logs_dir"], self.home / "da-flag")
        self.assertEqual(o["logs_dir"], "flag")
        self.assertEqual(v["state_dir"], self.home / "estado-env")
        self.assertTrue(o["state_dir"].startswith("ambiente"))
        self.assertEqual(v["teto_semanal_usd"], 50.0)
        self.assertTrue(o["teto_semanal_usd"].startswith("config"))

    def test_config_padrao_e_opcional_mas_explicita_e_obrigatoria(self):
        C.resolve({}, env={}, platform="darwin", home=self.home)  # sem config: ok
        with self.assertRaises(C.ConfigError):
            C.resolve({"config": str(self.home / "nao-existe.json")}, env={}, platform="darwin", home=self.home)

    def test_expande_variaveis_windows_e_til(self):
        cfg = self.home / "cfg.json"
        cfg.write_text(json.dumps({"logs_dir": "%USERPROFILE%/Logs", "state_dir": "~/estado"}), encoding="utf-8")
        env = {"USERPROFILE": str(self.home / "perfil")}
        v = C.resolve({"config": str(cfg)}, env=env, platform="darwin", home=self.home)["valores"]
        self.assertEqual(v["logs_dir"], self.home / "perfil" / "Logs")
        self.assertEqual(v["state_dir"], self.home / "estado")

    def test_ledger_dentro_das_pastas_das_lanes_e_recusado(self):
        logs = self.home / "logs"
        for ledger in (logs / "ledger.jsonl", self.home / ".transcentia" / "lanes" / "ledger.jsonl"):
            with self.assertRaises(C.ConfigError):
                C.resolve({"logs_dir": str(logs), "ledger": str(ledger)}, env={}, platform="darwin",
                          home=self.home)

    def test_teto_invalido(self):
        with self.assertRaises(C.ConfigError):
            C.resolve({}, env={C.ENV["teto_semanal_usd"]: "abc"}, platform="darwin", home=self.home)
        with self.assertRaises(C.ConfigError):
            C.resolve({}, env={C.ENV["teto_semanal_usd"]: "-1"}, platform="darwin", home=self.home)


if __name__ == "__main__":
    unittest.main()
