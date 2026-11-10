__attribute__((weak)) int common_entrypoint(void);
int frontend_table_entry_present(void) { return common_entrypoint != 0; }
