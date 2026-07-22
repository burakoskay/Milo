#ifndef MILO_HARDENING_INTEGRITY_H
#define MILO_HARDENING_INTEGRITY_H

int mh_integrity_check_launch(void);
int mh_integrity_check_envelope_load(void);
int mh_integrity_check_scan_loop(void);
int mh_integrity_check_settings_open(void);
int mh_integrity_check_signature_sync(void);
int mh_integrity_check_update_check(void);
int mh_integrity_check_paywall(void);
int mh_integrity_check_helper_connection(void);

#endif
