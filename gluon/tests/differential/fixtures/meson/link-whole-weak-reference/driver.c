int frontend_table_entry_present(void);
int driver_ready(void) { return frontend_table_entry_present(); }
