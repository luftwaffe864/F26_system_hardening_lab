{# DCIG System Hardening — mentor quick RESET
 # Clears quest progress, Phase-2 done flags, and re-plants Phase 1.
 # Same end state as applying hardening-lab; use this name when retesting.
 #
 #   sudo salt 'dcig-syslab-team30-ubuntu' state.apply hardening-lab-reset
 #   sudo salt 'win19_srv30' state.apply hardening-lab-reset
 #   sudo salt -L 'dcig-syslab-team30-ubuntu,win19_srv30' state.apply hardening-lab-reset
 #
 # Progress-only (no re-plant) — from the master:
 #   sudo salt 'dcig-syslab-team30-ubuntu' cmd.run 'rm -rf /home/student/.hardening-quest'
 #   sudo salt 'win19_srv30' cmd.run 'Remove-Item -Recurse -Force C:\Users\student\AppData\Local\HardeningQuest -EA SilentlyContinue' shell=powershell
 #}
{% set role = salt['grains.get']('role', '') %}
{% set is_windows = salt['grains.get']('os') == 'Windows' or salt['grains.get']('kernel') == 'Windows' %}
{% if is_windows %}
{% set files_root = salt['pillar.get']('hardening_lab:files_root_windows', 'C:\\HardeningLab\\src') %}
{% else %}
{% set files_root = salt['pillar.get']('hardening_lab:files_root', '/srv/salt/F26_system_hardening_lab') %}
{% endif %}
{% set scoreboard_url = salt['pillar.get']('hardening_lab:scoreboard_url', 'http://172.31.31.2:8080') %}
{% set secret = salt['pillar.get']('hardening_lab:secret', 'dcig-hardening-2026') %}
{% set student_pw = salt['pillar.get']('hardening_lab:student_password', 'Hardening2026!') %}

hardening-lab-reset-files:
  file.recurse:
    - name: {{ files_root }}
    - source: salt://F26_system_hardening_lab
    - clean: False
    - exclude_pat:
      - .git*
      - '*.pyc'
      - ANSWER_KEY*
{% if not is_windows %}
    - dir_mode: 755
    - file_mode: 755
{% endif %}

{% if role == 'hardening-linux' %}
hardening-lab-reset-linux:
  cmd.run:
    - name: >
        SCOREBOARD_URL='{{ scoreboard_url }}'
        HARDENING_SECRET='{{ secret }}'
        STUDENT_PW='{{ student_pw }}'
        bash {{ files_root }}/linux/setup_phase1.sh --no-switch
    - require:
      - file: hardening-lab-reset-files

{% elif role == 'hardening-windows' %}
hardening-lab-reset-windows:
  cmd.run:
    - name: >
        powershell.exe -ExecutionPolicy Bypass -File "{{ files_root }}\windows\setup_phase1.ps1"
        -ScoreboardUrl '{{ scoreboard_url }}'
        -Secret '{{ secret }}'
        -StudentPassword '{{ student_pw }}'
    - shell: powershell
    - require:
      - file: hardening-lab-reset-files

{% else %}
hardening-lab-reset-role-missing:
  test.fail_without_changes:
    - name: "Set grain role=hardening-linux|hardening-windows before applying hardening-lab-reset"
{% endif %}
