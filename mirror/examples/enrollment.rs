use laputa_mirror::db::Db;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let path = std::env::var("DB_PATH")?;
    let db = Db::open(&path)?;
    match args.as_slice() {
        [command, username] if command == "issue" => {
            let allowed = std::env::var("ALLOWED_USERS")?;
            if !allowed.split(',').map(str::trim).any(|name| name == username) {
                return Err("username is not in ALLOWED_USERS".into());
            }
            println!("{}", db.issue_enrollment(username)?);
        }
        [command, username] if command == "revoke" => db.revoke_enrollment(username)?,
        [command] if command == "list" => {
            for (user, kind, id, created) in db.inventory()? {
                println!("{user}\t{kind}\t{id}\t{created}");
            }
        }
        _ => return Err("usage: enrollment issue USER | revoke USER | list (DB_PATH and ALLOWED_USERS in environment)".into()),
    }
    Ok(())
}
