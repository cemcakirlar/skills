#!/usr/bin/env python3
# Universal AI Ecosystem Health & Skills Runner (SSoT: npx skills)
import os, json, sys, shutil, subprocess

HOME = os.path.expanduser("~")

MASTER_SKILLS = os.path.join(HOME, ".agents/skills")
DISABLED_SKILLS = os.path.join(HOME, ".agents/disabled-skills")
SKILL_LOCK_FILE = os.path.join(HOME, ".agents/.skill-lock.json")

def load_skill_lock_data():
    """~/.agents/.skill-lock.json dosyasını yükler ve skill bazlı kaynak sözlüğü döner."""
    if not os.path.exists(SKILL_LOCK_FILE):
        return {}
    try:
        with open(SKILL_LOCK_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

def get_disabled_skills_list():
    """Disabled skills dizini altındaki tüm skilleri (tüm derinliklerdeki alt klasörler dahil) tarar."""
    disabled = []
    if not os.path.exists(DISABLED_SKILLS):
        return disabled

    try:
        for root, dirs, files in os.walk(DISABLED_SKILLS):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            if "SKILL.md" in files:
                rel = os.path.relpath(root, DISABLED_SKILLS)
                if rel and rel != ".":
                    disabled.append(rel)
    except PermissionError:
        pass
    except Exception:
        pass

    return sorted(disabled)

def get_all_skills():
    """Tüm aktif ve pasif skilleri tarayıp döndürür."""
    active = []
    if os.path.exists(MASTER_SKILLS):
        try:
            for name in sorted(os.listdir(MASTER_SKILLS)):
                if not name.startswith(".") and os.path.isdir(os.path.join(MASTER_SKILLS, name)):
                    active.append(name)
        except Exception:
            pass

    disabled = get_disabled_skills_list()
    return active, disabled

def audit_installed_ai_tools():
    """Sistemde kurulu AI geliştirme araçlarını, IDE'leri ve yerel model çalıştırıcıları listeler."""
    print("=== KURULU YZ HARNESS VE ARAÇ TARAMASI (ENVANTER) ===")
    known_tools = [
        {"name": "Antigravity 2.0", "type": "Desktop App", "paths": ["/Applications/Antigravity.app"]},
        {"name": "Antigravity IDE", "type": "IDE/App", "paths": ["/Applications/Antigravity IDE.app"]},
        {"name": "Antigravity CLI (agy)", "type": "CLI", "cmds": ["agy"]},
        {"name": "Cursor", "type": "IDE/App", "paths": ["/Applications/Cursor.app"], "cmds": ["cursor"]},
        {"name": "Claude Code", "type": "CLI Agent", "cmds": ["claude"]},
        {"name": "Claude Desktop", "type": "Desktop App", "paths": ["/Applications/Claude.app"]},
        {"name": "Codex / OpenAI CLI", "type": "CLI", "cmds": ["codex"]},
        {"name": "Windsurf (Codeium)", "type": "IDE/App", "paths": ["/Applications/Windsurf.app"], "cmds": ["windsurf"]},
        {"name": "VS Code (GitHub Copilot / Cline / Roo)", "type": "IDE/App", "paths": ["/Applications/Visual Studio Code.app"], "cmds": ["code"]},
        {"name": "Aider", "type": "CLI Agent", "cmds": ["aider"]},
        {"name": "Ollama (Lokal LLM)", "type": "Local Engine", "paths": ["/Applications/Ollama.app"], "cmds": ["ollama"]},
        {"name": "LM Studio", "type": "Local Engine", "paths": ["/Applications/LM Studio.app"], "cmds": ["lms", "lmstudio"]},
        {"name": "LLM CLI (Datasette)", "type": "CLI", "cmds": ["llm"]},
    ]

    found_any = False
    for tool in known_tools:
        found_locations = []
        for p in tool.get("paths", []):
            if os.path.exists(p):
                found_locations.append(p)
        for cmd in tool.get("cmds", []):
            cmd_path = shutil.which(cmd)
            if cmd_path:
                found_locations.append(f"komut: {cmd_path}")

        if found_locations:
            found_any = True
            loc_str = ", ".join(found_locations)
            print(f"  * [KURULU] {tool['name']} ({tool['type']}) -> {loc_str}")

    if not found_any:
        print("  Belirtilen dizin veya komutlarda kurulu araç bulunamadı.")

def audit():
    """Temel havuz ve kilit dosyası durumunu denetler."""
    print("=== EVRENSEL SKILL HAVUZU VE KİLİT DOSYASI DENETİMİ ===")
    if not os.path.exists(MASTER_SKILLS):
        print(f"[UYARI] Master skill havuzu yok, oluşturuluyor: {MASTER_SKILLS}")
        os.makedirs(MASTER_SKILLS, exist_ok=True)
    else:
        active, disabled = get_all_skills()
        print(f"[OK] Master skill havuzu mevcut: {MASTER_SKILLS} ({len(active)} aktif skill)")
        if disabled:
            print(f"     Pasif/Arşivdeki Skiller: {len(disabled)} adet ({DISABLED_SKILLS})")

    # Lockfile denetimi (.skill-lock.json)
    if os.path.exists(SKILL_LOCK_FILE):
        lock_data = load_skill_lock_data()
        locked_skills = set(lock_data.get("skills", {}).keys())
        active_skills = set([x for x in os.listdir(MASTER_SKILLS) if not x.startswith(".")]) if os.path.exists(MASTER_SKILLS) else set()
        
        missing_on_disk = locked_skills - active_skills
        untracked = active_skills - locked_skills
        
        print(f"[OK] Skill kilit dosyası mevcut: {SKILL_LOCK_FILE} ({len(locked_skills)} kilitli paket)")
        if missing_on_disk:
            print(f"     ℹ️  Kilit dosyasında olup diskte aktif olmayan {len(missing_on_disk)} skill var: {', '.join(sorted(missing_on_disk)[:5])}...")
        if untracked:
            print(f"     ℹ️  Kilit dosyası dışı (Özel / Yerel) {len(untracked)} skill mevcut.")
    print()
    audit_installed_ai_tools()

def list_disabled_command():
    active, disabled = get_all_skills()
    active_set = set(active)

    print("============================================================")
    print(f"  DEVRE DIŞI / ARŞİVDEKİ SKILLER ({len(disabled)} adet)")
    print(f"  Dizin: {DISABLED_SKILLS}")
    print("============================================================")
    if disabled:
        categorized = {}
        uncategorized = []
        conflicts = []

        for s in disabled:
            base = os.path.basename(s)
            if base in active_set:
                conflicts.append((s, base))

            if "/" in s:
                cat, subpath = s.split("/", 1)
                categorized.setdefault(cat, []).append((subpath, base in active_set))
            else:
                uncategorized.append((s, base in active_set))

        for cat, items in sorted(categorized.items()):
            print(f"\n  [Kategori: {cat.upper()}] ({len(items)} adet)")
            for item, is_active in sorted(items):
                status_suffix = " ⚠️ (AYNI ZAMANDA AKTİFTE MEVCUT)" if is_active else ""
                print(f"    [-] {cat}/{item}{status_suffix}")

        if uncategorized:
            print(f"\n  [Genel / Kategorisiz] ({len(uncategorized)} adet)")
            for item, is_active in sorted(uncategorized):
                status_suffix = " ⚠️ (AYNI ZAMANDA AKTİFTE MEVCUT)" if is_active else ""
                print(f"    [-] {item}{status_suffix}")

        if conflicts:
            print(f"\n  ⚠️  DİKKAT: Toplam {len(conflicts)} skill hem aktifte hem pasifte mevcut!")

        print("\n  -> Aktifleştirmek için: python3 audit_environment.py --enable <skill_adi_veya_yolu>")
    else:
        print("  (Devre dışı bırakılmış skill bulunamadı veya arşiv boş)")
    print("============================================================")

def get_skill_origin(skill_name, lock_skills):
    """Bir skill'in nereden geldiğini tespit eder (lockfile veya dahili metadata)."""
    if skill_name in lock_skills:
        src = lock_skills[skill_name].get("source", "github")
        plugin = lock_skills[skill_name].get("pluginName")
        plugin_str = f" [{plugin}]" if plugin else ""
        return f"{src}{plugin_str}"

    smd = os.path.join(MASTER_SKILLS, skill_name, "SKILL.md")
    if os.path.exists(smd):
        try:
            with open(smd, "r", encoding="utf-8") as f:
                head = f.read(4096)
            if "publisher: google" in head:
                return "Google / Dahili"
            if "license:" in head:
                return "Açık Kaynak / Yerel"
        except Exception:
            pass
    return "Yerel / Untracked"

def list_skills_command():
    active, disabled = get_all_skills()
    lock_data = load_skill_lock_data()
    lock_skills = lock_data.get("skills", {})

    print("============================================================")
    print(f"  1. EVRENSEL AKTİF SKILLER ({len(active)} adet) - {MASTER_SKILLS}")
    print("============================================================")
    if active:
        for s in active:
            origin = get_skill_origin(s, lock_skills)
            print(f"  [+] {s:<32} (Kaynak: {origin})")
    else:
        print("  (Hiç aktif skill bulunamadı)")

    print()
    list_disabled_command()

def disable_skill_command(skill_name, force_purge=False):
    """
    Akıllı Silme Mekanizması:
    1. Eğer skill .skill-lock.json içinde VARSA:
       - npx skills remove çalıştırılır.
    2. Eğer skill yerel/untracked ise:
       - Kalıcı olarak silinmez; soft-delete yapılarak disabled-skills arşivine taşınır.
       - Sadece --purge veya force_purge=True ise kalıcı silinir.
    """
    if not skill_name or skill_name.strip() == "":
        print("[HATA] Lütfen işlem yapılacak skill adını belirtin.")
        sys.exit(1)

    skill_name = skill_name.strip().rstrip("/")

    if skill_name in ("skills-doctor", "skill-doctor", "agent-env-doctor", "cc-skill-doctor"):
        print(f"[UYARI] '{skill_name}' skilli kendisini kaldıramaz!")
        sys.exit(1)

    src = os.path.join(MASTER_SKILLS, skill_name)
    if not os.path.exists(src):
        print(f"[HATA] '{skill_name}' adında aktif bir skill bulunamadı: {src}")
        sys.exit(1)

    lock_data = load_skill_lock_data()
    is_external = skill_name in lock_data.get("skills", {})

    print("============================================================")
    print(f"  SKILL KALDIRMA İŞLEMİ: {skill_name}")
    print("============================================================")

    if is_external and not force_purge:
        pkg_info = lock_data["skills"][skill_name]
        source_repo = pkg_info.get("source", "Bilinmeyen kaynak")
        print(f"[BİLGİ] '{skill_name}' harici bir paket olarak tespit edildi ({source_repo}).")
        print("  -> Bu skill npx skills ile kaldırılıyor...\n")

        npx_path = shutil.which("npx")
        removed_via_npx = False
        if npx_path:
            cmd = [npx_path, "-y", "skills", "remove", skill_name, "-g", "-y"]
            try:
                ret = subprocess.run(cmd, check=False)
                if ret.returncode == 0:
                    removed_via_npx = True
            except Exception:
                pass

        if not removed_via_npx:
            try:
                shutil.rmtree(src, ignore_errors=True)
                if skill_name in lock_data.get("skills", {}):
                    del lock_data["skills"][skill_name]
                    with open(SKILL_LOCK_FILE, "w", encoding="utf-8") as f:
                        json.dump(lock_data, f, indent=2)
            except Exception as e:
                print(f"[UYARI] Temizleme sırasında hata: {e}")

        print(f"\n[BAŞARILI] Harici skill '{skill_name}' tamamen kaldırıldı.")
        return

    if force_purge:
        print(f"[UYARI] '{skill_name}' KALICI OLARAK SİLİNİYOR (--purge aktif)!")
        shutil.rmtree(src, ignore_errors=True)
        if skill_name in lock_data.get("skills", {}):
            del lock_data["skills"][skill_name]
            try:
                with open(SKILL_LOCK_FILE, "w", encoding="utf-8") as f:
                    json.dump(lock_data, f, indent=2)
            except Exception:
                pass
        print(f"[BAŞARILI] '{skill_name}' diskten tamamen silindi.")
        return

    # Yerel / Untracked Skill -> Soft Delete
    print(f"[KORUMA] '{skill_name}' yerel/özel geliştirilmiş bir skill olarak tespit edildi.")
    print("  -> İnternetten tekrar otomatik indirilemeyeceği için veri kaybını önlemek amacıyla")
    print("  -> KALICI OLARAK SİLİNMEDİ; 'disabled-skills' arşivine taşındı (Soft-Delete).")

    os.makedirs(DISABLED_SKILLS, exist_ok=True)
    dst = os.path.join(DISABLED_SKILLS, skill_name)

    if os.path.exists(dst):
        print(f"[UYARI] '{skill_name}' zaten disabled-skills içinde mevcut: {dst}")
        i = 1
        while os.path.exists(f"{dst}.backup_{i}"):
            i += 1
        backup_dst = f"{dst}.backup_{i}"
        os.rename(dst, backup_dst)
        print(f"       Mevcut pasif kopya '{backup_dst}' olarak yedeklendi.")

    parent_dir = os.path.dirname(dst)
    if parent_dir and not os.path.exists(parent_dir):
        os.makedirs(parent_dir, exist_ok=True)

    shutil.move(src, dst)
    print(f"\n[BAŞARILI] '{skill_name}' güvenle arşivlendi (Soft-Delete)!")
    print(f"  Arşiv Yeri : {dst}")
    print(f"  -> Tekrar açmak için: python3 audit_environment.py --enable {skill_name}\n")

def enable_skill_command(skill_name):
    """Devre dışı bırakılmış skilli tekrar aktif havuza taşır."""
    if not skill_name or skill_name.strip() == "":
        print("[HATA] Lütfen aktifleştirilecek skill adını belirtin.")
        sys.exit(1)

    skill_name = skill_name.strip().rstrip("/")
    target_basename = os.path.basename(skill_name)

    direct_path = os.path.join(DISABLED_SKILLS, skill_name)
    matched_path = None

    if os.path.exists(direct_path) and os.path.isdir(direct_path):
        matched_path = direct_path
    else:
        disabled_list = get_disabled_skills_list()
        exact_matches = []
        name_matches = []

        for rel in disabled_list:
            if rel == skill_name:
                exact_matches.append(rel)
            elif os.path.basename(rel) == target_basename:
                name_matches.append(rel)

        candidates = exact_matches if exact_matches else name_matches

        if len(candidates) == 1:
            matched_path = os.path.join(DISABLED_SKILLS, candidates[0])
            target_basename = os.path.basename(candidates[0])
        elif len(candidates) > 1:
            print(f"[UYARI] Birden fazla eşleşen pasif skill bulundu:")
            for c in candidates:
                print(f"  - {c}")
            print("Lütfen tam göreceli yol belirterek çalıştırın (Örn: python3 audit_environment.py --enable azure/azure-kubernetes).")
            sys.exit(1)
        else:
            print(f"[HATA] '{skill_name}' adında devre dışı bırakılmış bir skill bulunamadı ({DISABLED_SKILLS})")
            sys.exit(1)

    dst = os.path.join(MASTER_SKILLS, target_basename)
    if os.path.exists(dst):
        print(f"[HATA] '{target_basename}' zaten aktif havuzda mevcut: {dst}")
        sys.exit(1)

    os.makedirs(MASTER_SKILLS, exist_ok=True)
    shutil.move(matched_path, dst)
    print(f"\n[BAŞARILI] '{target_basename}' başarıyla yeniden aktifleştirildi!")
    print(f"  Kaynak : {matched_path}")
    print(f"  Hedef  : {dst}")

def update_skills_command():
    """npx skills update -g çalıştırarak kilitli tüm harici skilleri günceller."""
    print("============================================================")
    print("  SKILL GÜNCELLEMESİ (npx skills update -g)")
    print("============================================================")
    npx_path = shutil.which("npx")
    if not npx_path:
        print("[HATA] 'npx' komutu bulunamadı. Lütfen Node.js ve npm kurulu olduğundan emin olun.")
        sys.exit(1)

    cmd = [npx_path, "-y", "skills", "update", "-g", "-y"]
    print(f"Çalıştırılıyor: {' '.join(cmd)}\n")
    try:
        ret = subprocess.run(cmd, check=False)
        if ret.returncode == 0:
            print("\n[BAŞARILI] Tüm harici skiller en güncel sürümlerine güncellendi.")
        else:
            print(f"\n[UYARI] Güncelleme işlemi kod {ret.returncode} ile tamamlandı.")
    except Exception as e:
        print(f"[HATA] Güncelleme çalıştırılamadı: {e}")

def install_skill_command(package_name):
    """npx skills add <package> -g --all -y çalıştırarak yeni skill ekler."""
    if not package_name or package_name.strip() == "":
        print("[HATA] Lütfen kurulacak repo veya paket adını belirtin (Örn: vercel-labs/skills).")
        sys.exit(1)

    print("============================================================")
    print(f"  YENİ SKILL KURULUMU: {package_name}")
    print("============================================================")
    npx_path = shutil.which("npx")
    if not npx_path:
        print("[HATA] 'npx' komutu bulunamadı. Lütfen Node.js ve npm kurulu olduğundan emin olun.")
        sys.exit(1)

    cmd = [npx_path, "-y", "skills", "add", package_name, "-g", "--all", "-y"]
    print(f"Çalıştırılıyor: {' '.join(cmd)}\n")
    try:
        ret = subprocess.run(cmd, check=False)
        if ret.returncode == 0:
            print(f"\n[BAŞARILI] '{package_name}' paketi evrensel skill havuzuna başarıyla kuruldu.")
        else:
            print(f"\n[UYARI] Kurulum kod {ret.returncode} ile tamamlandı.")
    except Exception as e:
        print(f"[HATA] Kurulum çalıştırılamadı: {e}")

def clean_lockfile_command():
    """Kilit dosyasını (.skill-lock.json) tarar; diskte artık bulunmayan yetim kayıtları temizler."""
    print("============================================================")
    print("  KİLİT DOSYASI TEMİZLİĞİ (.skill-lock.json Prune)")
    print("============================================================")
    if not os.path.exists(SKILL_LOCK_FILE):
        print(f"[BİLGİ] Kilit dosyası bulunamadı: {SKILL_LOCK_FILE}")
        return

    try:
        with open(SKILL_LOCK_FILE, "r", encoding="utf-8") as f:
            lock_data = json.load(f)
    except Exception as e:
        print(f"[HATA] Kilit dosyası okunamadı: {e}")
        return

    skills_dict = lock_data.get("skills", {})
    if not skills_dict:
        print("[BİLGİ] Kilit dosyasında kayıtlı skill bulunamadı.")
        return

    active_skills = set([x for x in os.listdir(MASTER_SKILLS) if not x.startswith(".")]) if os.path.exists(MASTER_SKILLS) else set()

    orphaned = []
    cleaned_skills = {}

    for skill_name, skill_info in skills_dict.items():
        if skill_name in active_skills:
            cleaned_skills[skill_name] = skill_info
        else:
            orphaned.append(skill_name)

    if not orphaned:
        print(f"[OK] Kilit dosyası tertemiz! Tüm kilitli kayıtlar ({len(cleaned_skills)} adet) diskte mevcut.")
        return

    # Güvenlik amaçlı yedek alalım
    backup_file = SKILL_LOCK_FILE + ".bak"
    try:
        shutil.copy2(SKILL_LOCK_FILE, backup_file)
        print(f"[YEDEK] Kilit dosyası yedeklendi: {backup_file}")
    except Exception as e:
        print(f"[UYARI] Yedek alınamadı ({e}), işleme devam ediliyor...")

    lock_data["skills"] = cleaned_skills

    try:
        with open(SKILL_LOCK_FILE, "w", encoding="utf-8") as f:
            json.dump(lock_data, f, indent=2, ensure_ascii=False)
        print(f"\n[BAŞARILI] Kilit dosyasından diskte bulunmayan {len(orphaned)} yetim kayıt temizlendi:")
        for s in sorted(orphaned):
            print(f"  [-] {s}")
        print(f"\nGüncel kilitli skill sayısı: {len(cleaned_skills)}")
    except Exception as e:
        print(f"[HATA] Temizlenen kilit dosyası yazılamadı: {e}")

if __name__ == "__main__":
    args = sys.argv[1:]

    if "--list-skills" in args or "-l" in args:
        list_skills_command()
        sys.exit(0)

    if "--list-disabled" in args or "--disabled" in args:
        list_disabled_command()
        sys.exit(0)

    if "--update-skills" in args or "--update" in args or "-u" in args:
        update_skills_command()
        sys.exit(0)

    if "--clean-lock" in args or "--clean" in args or "--prune" in args:
        clean_lockfile_command()
        sys.exit(0)

    if "--install" in args or "-i" in args:
        flag = "--install" if "--install" in args else "-i"
        idx = args.index(flag)
        if len(args) > idx + 1 and not args[idx + 1].startswith("-"):
            pkg = args[idx + 1]
            install_skill_command(pkg)
            sys.exit(0)
        else:
            print(f"[HATA] Kullanım: python3 audit_environment.py {flag} <repo/paket>")
            sys.exit(1)

    if "--uninstall" in args or "--disable" in args or "-d" in args:
        flag = "--uninstall" if "--uninstall" in args else ("--disable" if "--disable" in args else "-d")
        idx = args.index(flag)
        force_purge = "--purge" in args or "--hard" in args
        if len(args) > idx + 1 and not args[idx + 1].startswith("-"):
            target_skill = args[idx + 1]
            disable_skill_command(target_skill, force_purge=force_purge)
            sys.exit(0)
        else:
            print(f"[HATA] Kullanım: python3 audit_environment.py {flag} <skill-adi> [--purge]")
            sys.exit(1)

    if "--purge" in args:
        idx = args.index("--purge")
        if len(args) > idx + 1 and not args[idx + 1].startswith("-"):
            target_skill = args[idx + 1]
            disable_skill_command(target_skill, force_purge=True)
            sys.exit(0)

    if "--enable" in args or "-e" in args:
        flag = "--enable" if "--enable" in args else "-e"
        idx = args.index(flag)
        if len(args) > idx + 1 and not args[idx + 1].startswith("-"):
            target_skill = args[idx + 1]
            enable_skill_command(target_skill)
            sys.exit(0)
        else:
            print(f"[HATA] Kullanım: python3 audit_environment.py {flag} <skill-adi>")
            sys.exit(1)

    # Varsayılan Audit akışı
    audit()
    print("\n" + "="*60)
    print("Komutlar:")
    print("  --list-skills               : Aktif, pasif, eklenti ve dahili tüm skilleri kaynaklarıyla listeler")
    print("  --list-disabled             : Sadece pasif/arşivdeki skilleri kategorileriyle listeler")
    print("  --update-skills             : Harici tüm skilleri npx skills CLI ile en son sürüme günceller")
    print("  --clean-lock (--prune)      : Kilit dosyasını (.skill-lock.json) diskte olmayan yetim kayıtlardan temizler")
    print("  --install <repo/paket>      : npx skills ile yeni skill kurar ve ortama bağlar")
    print("  --uninstall <skill_adi>     : Skilli kaldırır (harici ise npx skills ile siler, yerel ise arşivler)")
    print("  --purge <skill_adi>         : Skilli yerel olsa dahi kalıcı olarak siler")
    print("  --enable <skill_adi>        : Pasif skilli tekrar aktifleştirir")
    print("="*60)
