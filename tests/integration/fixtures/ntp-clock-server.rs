use std::{env, error::Error, fs, io, net::UdpSocket};

#[repr(C)]
struct Timespec {
    seconds: i64,
    nanoseconds: i64,
}

unsafe extern "C" {
    fn clock_gettime(clock: i32, value: *mut Timespec) -> i32;
}

fn raw_ms() -> io::Result<u64> {
    let mut value = Timespec { seconds: 0, nanoseconds: 0 };
    // SAFETY: value points to writable timespec storage for the duration of this call.
    if unsafe { clock_gettime(4, &mut value) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(value.seconds as u64 * 1000 + value.nanoseconds as u64 / 1_000_000)
}

fn timestamp(base_ms: u64, origin_raw_ms: u64) -> io::Result<[u8; 8]> {
    let millis = base_ms + raw_ms()? - origin_raw_ms;
    let seconds = (millis / 1000 + 2_208_988_800) as u32;
    let fraction = (((millis % 1000) << 32) / 1000) as u32;
    let mut out = [0; 8];
    out[..4].copy_from_slice(&seconds.to_be_bytes());
    out[4..].copy_from_slice(&fraction.to_be_bytes());
    Ok(out)
}

fn main() -> Result<(), Box<dyn Error>> {
    let mut args = env::args().skip(1);
    let first = args.next().ok_or("missing base time")?;
    if first == "--raw" {
        println!("{}", raw_ms()?);
        return Ok(());
    }
    let base_ms: u64 = first.parse()?;
    let origin_raw_ms: u64 = args.next().ok_or("missing raw origin")?.parse()?;
    let ready = args.next().ok_or("missing readiness path")?;
    let socket = UdpSocket::bind("127.0.0.1:32123")?;
    fs::write(ready, b"ready\n")?;
    let mut request = [0; 1024];
    let mut count = 0_u64;
    loop {
        let (len, peer) = socket.recv_from(&mut request)?;
        count += 1;
        fs::write("/run/ntp-oracle-count", count.to_string())?;
        if len < 48 || request[0] & 7 != 3 {
            continue;
        }
        let time = timestamp(base_ms, origin_raw_ms)?;
        let mut response = [0; 48];
        response[0] = 0x24;
        response[1] = 1;
        response[2] = request[2];
        response[3] = (-20_i8) as u8;
        response[8..12].copy_from_slice(&16_u32.to_be_bytes());
        response[12..16].copy_from_slice(b"LOCL");
        response[16..24].copy_from_slice(&time);
        response[24..32].copy_from_slice(&request[40..48]);
        response[32..40].copy_from_slice(&time);
        response[40..48].copy_from_slice(&time);
        socket.send_to(&response, peer)?;
    }
}
