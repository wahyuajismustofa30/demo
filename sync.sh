#!/usr/bin/env bash
# ==========================================
# SINKRONISASI GIT: tarik → commit → push
# - Menarik commit terbaru dari GitHub (rebase, perubahan lokal diamankan otomatis).
# - Commit perubahan lokal setelah diperiksa dari file rahasia.
# - Push, termasuk commit lama yang belum terkirim dan branch baru.
# Simpan file ini dengan akhir baris LF (bukan CRLF) agar bisa dijalankan Git Bash.
# ==========================================
set -Eeuo pipefail

REMOTE="${REMOTE:-origin}"
BRANCH="main"
REMOTE_EXISTS=0
MAX_FILE_MB=50   # GitHub menolak file > 100 MB dan memperingatkan file > 50 MB

# ==========================================
# UTILITAS
# ==========================================
log_error() { printf '❌ [%s] %s\n' "$1" "$2" >&2; }

on_exit() {
  local code=$?
  if [[ -t 0 ]]; then
    echo
    read -r -p "Tekan Enter untuk keluar..." _ || true
  fi
  exit "$code"
}
trap on_exit EXIT
trap 'log_error "BARIS $LINENO" "Perintah gagal (kode $?)."' ERR

confirm() {
  local answer=""
  read -r -p "$1 (y/N): " answer || return 1
  [[ "${answer,,}" =~ ^(y|ya|yes)$ ]]
}

remote_ref() { echo "refs/remotes/${REMOTE}/${BRANCH}"; }

# ==========================================
# VALIDASI REPOSITORY
# ==========================================
check_repository() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_error "REPOSITORY" "Folder ini belum menjadi repository Git."
    exit 1
  fi
  cd "$(git rev-parse --show-toplevel)"

  if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    log_error "REMOTE" "Remote '$REMOTE' belum dikonfigurasi."
    echo "Tambahkan dengan: git remote add $REMOTE <URL_REPOSITORY_GITHUB>"
    exit 1
  fi

  BRANCH="$(git branch --show-current)"
  if [[ -z "$BRANCH" ]]; then
    log_error "BRANCH" "HEAD dalam kondisi detached. Pindah ke sebuah branch terlebih dahulu."
    exit 1
  fi

  if [[ -d "$(git rev-parse --git-path rebase-merge)" || -d "$(git rev-parse --git-path rebase-apply)" ]]; then
    log_error "REBASE" "Masih ada proses rebase yang belum selesai."
    echo "Selesaikan dengan 'git rebase --continue' atau batalkan dengan 'git rebase --abort'."
    exit 1
  fi
  if [[ -f "$(git rev-parse --git-path MERGE_HEAD)" ]]; then
    log_error "MERGE" "Masih ada proses merge yang belum selesai."
    echo "Selesaikan dengan 'git commit' atau batalkan dengan 'git merge --abort'."
    exit 1
  fi

  echo "📂 Repository : $(basename "$PWD")"
  echo "🌿 Branch     : $BRANCH"
  echo "🔗 Remote     : $REMOTE ($(git remote get-url "$REMOTE"))"
}

# ==========================================
# TARIK PERUBAHAN DARI GITHUB
# ==========================================
sync_remote() {
  echo
  echo "🌐 Mengambil informasi terbaru dari GitHub..."
  if ! git fetch --prune "$REMOTE"; then
    log_error "FETCH" "Gagal menghubungi remote. Periksa koneksi, URL, dan autentikasi."
    exit 1
  fi

  if ! git show-ref --verify --quiet "$(remote_ref)"; then
    REMOTE_EXISTS=0
    echo "🆕 Branch '$BRANCH' belum ada di GitHub; akan dibuat saat push."
    return 0
  fi
  REMOTE_EXISTS=1

  if ! git merge-base HEAD "$REMOTE/$BRANCH" >/dev/null 2>&1; then
    log_error "HISTORY" "Riwayat lokal dan remote tidak memiliki basis bersama."
    echo "Jangan reset otomatis; periksa kedua riwayat secara manual."
    exit 1
  fi

  local ahead behind
  read -r ahead behind <<< "$(git rev-list --left-right --count "HEAD...$REMOTE/$BRANCH")"
  echo "Commit lokal belum terkirim : $ahead"
  echo "Commit baru di GitHub       : $behind"

  if (( behind == 0 )); then
    echo "✅ Tidak ada commit baru di GitHub."
    return 0
  fi

  echo "📥 Menerapkan commit dari GitHub (rebase)..."
  # Data sudah di-fetch; rebase langsung tanpa menghubungi jaringan lagi.
  if ! git rebase --autostash "$REMOTE/$BRANCH"; then
    log_error "REBASE" "Ada konflik saat menggabungkan perubahan."
    echo
    git status --short || true
    echo
    echo "Cara menyelesaikan:"
    echo "  1. Buka file bertanda konflik (<<<<<<< ======= >>>>>>>) lalu perbaiki."
    echo "  2. git add <file>"
    echo "  3. git rebase --continue"
    echo "Untuk membatalkan dan kembali ke kondisi semula: git rebase --abort"
    echo "Bila perubahan belum di-commit tidak kembali, cek: git stash list"
    exit 1
  fi
  echo "✅ Perubahan dari GitHub sudah diterapkan."
}

# ==========================================
# PEMERIKSAAN KEAMANAN SEBELUM COMMIT
# ==========================================
# Mengembalikan 1 bila ada file rahasia / token / file terlalu besar di staging.
check_staged_safety() {
  local problems=0 f size

  # 1. Nama file yang tidak boleh masuk repository.
  while IFS= read -r f; do
    case "${f##*/}" in
      .dev.vars | .env | .env.* | *.pem | *.key | *.p12 | *.pfx | id_rsa* | credentials*.json | *service-account*.json)
        [[ "${f##*/}" == *.example ]] && continue
        log_error "RAHASIA" "File sensitif ikut di-stage: $f"
        problems=1 ;;
    esac
  done < <(git diff --cached --name-only --diff-filter=AM)

  # 2. Isi yang menyerupai token atau private key (hanya baris yang ditambahkan).
  local hits
  hits="$(git diff --cached -U0 --diff-filter=AM \
    | grep -nE '^\+.*(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16})' \
    | cut -c1-120 || true)"
  if [[ -n "$hits" ]]; then
    log_error "RAHASIA" "Ditemukan teks yang menyerupai token/private key:"
    echo "$hits" | sed 's/\(ghp_\|github_pat_\|gho_\)[A-Za-z0-9_]\{4\}[A-Za-z0-9_]*/\1****/g'
    problems=1
  fi

  # 3. File terlalu besar untuk GitHub.
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    size=$(( $(wc -c < "$f") / 1024 / 1024 ))
    if (( size >= MAX_FILE_MB )); then
      log_error "UKURAN" "$f berukuran ${size} MB; GitHub menolak file di atas 100 MB."
      problems=1
    fi
  done < <(git diff --cached --name-only --diff-filter=AM)

  return "$problems"
}

# ==========================================
# COMMIT
# ==========================================
commit_changes() {
  echo
  if [[ -z "$(git status --porcelain)" ]]; then
    echo "📦 Tidak ada perubahan file lokal."
    return 0
  fi

  echo "📝 Perubahan lokal:"
  git status --short
  echo
  if ! confirm "Commit semua perubahan di atas?"; then
    echo "⏹️ Commit dilewati."
    return 0
  fi

  git add -A
  if git diff --cached --quiet; then
    echo "ℹ️ Tidak ada perubahan yang dapat di-commit."
    return 0
  fi

  if ! check_staged_safety; then
    git reset -q   # kembalikan staging; file di folder tidak diubah
    echo
    echo "⛔ Commit dibatalkan demi keamanan. Tidak ada yang dikirim."
    echo "   Tambahkan file rahasia ke .gitignore, atau hapus token dari kodenya,"
    echo "   lalu jalankan ulang skrip ini."
    exit 1
  fi

  local message="" default
  default="Auto-sync $(date '+%H:%M %d/%m/%Y')"
  read -r -p "Pesan commit [$default]: " message || true
  message="${message:-$default}"

  if ! git commit -q -m "$message"; then
    log_error "COMMIT" "Commit gagal. Periksa pesan error di atas."
    exit 1
  fi
  echo "✅ Commit dibuat: $message"
}

# ==========================================
# PUSH
# ==========================================
push_changes() {
  local ahead=0
  if (( REMOTE_EXISTS )); then
    ahead="$(git rev-list --count "$REMOTE/$BRANCH..HEAD")"
    if (( ahead == 0 )); then
      echo "✅ GitHub sudah sama dengan lokal; tidak ada yang perlu di-push."
      return 0
    fi
    echo
    echo "🚀 Mengirim $ahead commit ke GitHub..."
  else
    echo
    echo "🚀 Membuat branch '$BRANCH' di GitHub dan mengirim commit..."
  fi

  # -u: atur upstream agar 'git push' / 'git pull' biasa juga langsung bekerja.
  if git push -u "$REMOTE" "$BRANCH"; then
    echo "✅ Push berhasil."
    return 0
  fi

  # Push ditolak biasanya karena ada commit baru di GitHub sejak fetch tadi: coba sekali lagi.
  echo "⚠️ Push ditolak. Menarik perubahan terbaru lalu mencoba sekali lagi..."
  sync_remote
  if git push -u "$REMOTE" "$BRANCH"; then
    echo "✅ Push berhasil pada percobaan kedua."
    return 0
  fi

  log_error "PUSH" "Push gagal."
  echo "Coba jalankan manual:"
  echo "  git fetch $REMOTE"
  echo "  git rebase $REMOTE/$BRANCH"
  echo "  git push -u $REMOTE $BRANCH"
  exit 1
}

# ==========================================
# EKSEKUSI UTAMA
# ==========================================
main() {
  echo "🚀 Memulai sinkronisasi Git..."
  check_repository
  sync_remote
  commit_changes
  push_changes
  echo
  echo "✅ Proses selesai."
}

main