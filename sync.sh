
#!/usr/bin/env bash
set -Eeuo pipefail

REMOTE="origin"
BRANCH=""

# ==========================================
# LOGGING
# ==========================================
log_error() {
  printf '❌ [%s] %s\n' "$1" "$2" >&2
}

pause_exit() {
  local code="${1:-1}"
  read -r -p "Tekan Enter untuk keluar..." _ || true
  exit "$code"
}

confirm() {
  local answer
  read -r -p "$1 (y/n): " answer || return 1
  [[ "$answer" =~ ^[Yy]$ ]]
}

# ==========================================
# VALIDASI REPOSITORY
# ==========================================

check_repository() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_error "REPOSITORY" "Folder ini belum menjadi repository Git."
    pause_exit 1
  fi

  if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    log_error "REMOTE" "Remote '$REMOTE' belum dikonfigurasi."
    echo "Tambahkan remote dengan:"
    echo "  git remote add origin <URL_REPOSITORY_GITHUB>"
    pause_exit 1
  fi

  BRANCH="$(git branch --show-current)"

  if [[ -z "$BRANCH" ]]; then
    log_error "BRANCH" "HEAD dalam kondisi detached."
    echo "Pindah ke branch terlebih dahulu."
    pause_exit 1
  fi

  echo "📂 Repository : $(basename "$(git rev-parse --show-toplevel)")"
  echo "🌿 Branch lokal: $BRANCH"
  echo "🔗 Remote      : $REMOTE"

  if ! git show-ref --verify --quiet \
    "refs/remotes/${REMOTE}/${BRANCH}"; then
    echo "⚠️ Branch remote '$REMOTE/$BRANCH' belum ditemukan."
    echo "Script tidak akan membuat branch remote secara otomatis."

    if ! confirm "Lanjutkan dengan branch lokal '$BRANCH'?"; then
      pause_exit 1
    fi
  fi

  if [[ -d "$(git rev-parse --git-path rebase-merge)" ||
        -d "$(git rev-parse --git-path rebase-apply)" ]]; then
    log_error "REBASE" "Masih ada proses rebase yang belum selesai."
    git status
    pause_exit 1
  fi

  if [[ -f "$(git rev-parse --git-path MERGE_HEAD)" ]]; then
    log_error "MERGE" "Masih ada proses merge yang belum selesai."
    git status
    pause_exit 1
  fi
}

# ==========================================
# FETCH DAN SINKRONISASI
# ==========================================
sync_remote() {
  echo "🌐 Mengambil informasi terbaru dari GitHub..."

  if ! git fetch "$REMOTE" "$BRANCH"; then
    log_error "FETCH" "Gagal mengambil data dari remote."
    echo "Periksa koneksi, URL remote, autentikasi, dan branch."
    pause_exit 1
  fi

  if ! git show-ref --verify --quiet \
    "refs/remotes/${REMOTE}/${BRANCH}"; then
    log_error "REMOTE_BRANCH" \
      "Branch ${REMOTE}/${BRANCH} belum tersedia."
    echo "Periksa apakah branch sudah dibuat dan memiliki commit."
    pause_exit 1
  fi

  local local_commit remote_commit
  local_commit="$(git rev-parse HEAD)"
  remote_commit="$(git rev-parse "${REMOTE}/${BRANCH}")"

  if [[ "$local_commit" == "$remote_commit" ]]; then
    echo "✅ HEAD lokal sudah sama dengan remote."
    return 0
  fi

  echo "🔄 Memeriksa perbedaan commit..."

  if ! git merge-base HEAD "${REMOTE}/${BRANCH}" >/dev/null 2>&1; then
    log_error "HISTORY" "Riwayat lokal dan remote tidak memiliki basis bersama."
    echo "Jangan lakukan reset otomatis; periksa riwayat kedua repository."
    pause_exit 1
  fi

  local counts behind ahead
  counts="$(git rev-list --left-right --count \
    "HEAD...${REMOTE}/${BRANCH}")"
  read -r ahead behind <<< "$counts"

  echo "Commit lokal saja : $ahead"
  echo "Commit remote saja: $behind"

  if (( behind > 0 )); then
    echo "📥 Menjalankan pull --rebase..."

    if ! git pull --rebase --autostash "$REMOTE" "$BRANCH"; then
      log_error "PULL" "Sinkronisasi gagal."

      echo
      echo "Status Git saat ini:"
      git status || true

      echo
      echo "Jika ada konflik:"
      echo "  1. Periksa file konflik dengan git status."
      echo "  2. Perbaiki file secara manual."
      echo "  3. Stage file yang telah diperbaiki."
      echo "  4. Jalankan git rebase --continue."
      echo
      echo "Untuk membatalkan rebase:"
      echo "  git rebase --abort"
      echo
      echo "Jalankan ulang script setelah proses selesai."
      pause_exit 1
    fi
  else
    echo "ℹ️ Remote tidak memiliki commit baru."
  fi

  echo "✅ Pemeriksaan sinkronisasi selesai."
}

# ==========================================
# COMMIT DAN PUSH
# ==========================================
commit_and_push() {
  if [[ -n "$(git status --porcelain)" ]]; then
    echo
    echo "📝 Perubahan lokal terdeteksi:"
    git status --short

    echo
    echo "⚠️ Periksa daftar di atas sebelum melanjutkan."
    echo "Pastikan tidak ada file rahasia atau file yang tidak ingin dikirim."

    if confirm "Commit seluruh perubahan yang ditampilkan?"; then
      git add -A

      if git diff --cached --quiet; then
        echo "ℹ️ Tidak ada perubahan yang dapat di-commit."
        return 0
      fi

      local timestamp
      timestamp="$(date '+%H:%M %d/%m/%Y')"

      if ! git commit -m "Auto-sync $timestamp"; then
        log_error "COMMIT" "Commit gagal."
        echo "Periksa git status dan pesan error di atas."
        pause_exit 1
      fi

      echo "🚀 Mendorong commit ke GitHub..."

      if ! git push "$REMOTE" "$BRANCH"; then
        log_error "PUSH" "Push gagal."
        echo "Periksa status repository dan jalankan:"
        echo "  git fetch origin"
        echo "  git pull --rebase origin main"
        echo "  git push origin main"
        pause_exit 1
      fi

      echo "✅ Commit dan push berhasil."
    else
      echo "⏹️ Commit dan push dibatalkan."
    fi
  else
    echo "📦 Tidak ada perubahan lokal."
  fi
}

# ==========================================
# EKSEKUSI UTAMA
# ==========================================
main() {
  echo "🚀 Memulai sinkronisasi Git..."

  check_repository
  sync_remote
  commit_and_push

  echo
  echo "✅ Proses selesai."
}

trap 'rc=$?; printf "\n❌ Error pada baris %s (kode %s).\n" "$LINENO" "$rc" >&2' ERR

main
pause_exit 0
