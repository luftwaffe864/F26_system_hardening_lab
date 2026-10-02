{# DCIG System Hardening — apply Phase 1 by grain `role`
 #   hardening-linux  → ubuntuNN
 #   hardening-windows → win19_srvNN
 #
 # Homelab (1 pair): set the same grains on ubuntu01 + win19_srv01 and apply.
 #}
{% set role = salt['grains.get']('role', '') %}
{% set files_root = salt['pillar.get']('hardening_lab:files_root', '/srv/salt/F26_system_hardening_lab') %}
{% set scoreboard_url = salt['pillar.get']('hardening_lab:scoreboard_url', 'http://192.168.1.7:8080') %}
{% set secret = salt['pillar.get']('hardening_lab:secret', 'dcig-hardening-2026') %}
{% set student_pw = salt['pillar.get']('hardening_lab:student_password', 'Hardening2026!') %}

hardening-lab-files:
  file.recurse:
    - name: {{ files_root }}
    - source: salt://F26_system_hardening_lab
    - clean: False
    - dir_mode: 755
    - file_mode: 755

{% if role == 'hardening-linux' %}
hardening-lab-linux-phase1:
  cmd.run:
    - name: >
        SCOREBOARD_URL='{{ scoreboard_url }}'
        HARDENING_SECRET='{{ secret }}'
        STUDENT_PW='{{ student_pw }}'
        bash {{ files_root }}/linux/setup_phase1.sh --no-switch
    - require:
      - file: hardening-lab-files

{% elif role == 'hardening-windows' %}
hardening-lab-windows-phase1:
  cmd.run:
    - name: >
        powershell.exe -ExecutionPolicy Bypass -File {{ files_root }}\windows\setup_phase1.ps1
        -ScoreboardUrl '{{ scoreboard_url }}'
        -Secret '{{ secret }}'
        -StudentPassword '{{ student_pw }}'
    - shell: powershell
    - require:
      - file: hardening-lab-files

{% else %}
hardening-lab-role-missing:
  test.fail_without_changes:
    - name: "Set grain role=hardening-linux|hardening-windows before applying hardening-lab"
{% endif %}
