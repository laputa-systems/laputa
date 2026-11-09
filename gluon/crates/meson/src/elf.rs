use std::io::Write;
use std::path::Path;

const DT_NULL: i64 = 0;
const DT_RPATH: i64 = 15;
const DT_RUNPATH: i64 = 29;
const DT_MIPS_RLD_MAP_REL: i64 = 1879048245;
const SHT_DYNAMIC: u32 = 6;

struct Layout {
    is64: bool,
    little_endian: bool,
}

impl Layout {
    fn word_size(&self) -> usize {
        if self.is64 {
            8
        } else {
            4
        }
    }

    fn dynamic_entry_size(&self) -> usize {
        self.word_size() * 2
    }

    fn section_header_size(&self) -> usize {
        if self.is64 {
            64
        } else {
            40
        }
    }

    fn dynsym_entry_size(&self) -> usize {
        if self.is64 {
            24
        } else {
            16
        }
    }
}

#[derive(Clone)]
struct DynamicEntry {
    tag: i64,
    value: u64,
}

#[derive(Clone)]
struct Section {
    name: String,
    section_type: u32,
    offset: u64,
    size: u64,
    entry_size: u64,
}

fn read_u16(data: &[u8], offset: usize, little_endian: bool) -> Result<u16, String> {
    let bytes = data
        .get(offset..offset + 2)
        .ok_or_else(|| "truncated ELF header".to_string())?;
    let array = [bytes[0], bytes[1]];
    Ok(if little_endian {
        u16::from_le_bytes(array)
    } else {
        u16::from_be_bytes(array)
    })
}

fn read_u32(data: &[u8], offset: usize, little_endian: bool) -> Result<u32, String> {
    let bytes = data
        .get(offset..offset + 4)
        .ok_or_else(|| "truncated ELF data".to_string())?;
    let array = [bytes[0], bytes[1], bytes[2], bytes[3]];
    Ok(if little_endian {
        u32::from_le_bytes(array)
    } else {
        u32::from_be_bytes(array)
    })
}

fn read_u64(data: &[u8], offset: usize, little_endian: bool) -> Result<u64, String> {
    let bytes = data
        .get(offset..offset + 8)
        .ok_or_else(|| "truncated ELF data".to_string())?;
    let array = [
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
    ];
    Ok(if little_endian {
        u64::from_le_bytes(array)
    } else {
        u64::from_be_bytes(array)
    })
}

fn write_u32(data: &mut [u8], offset: usize, value: u32, little_endian: bool) -> Result<(), String> {
    let bytes = if little_endian {
        value.to_le_bytes()
    } else {
        value.to_be_bytes()
    };
    data.get_mut(offset..offset + 4)
        .ok_or_else(|| "truncated ELF data".to_string())?
        .copy_from_slice(&bytes);
    Ok(())
}

fn write_u64(data: &mut [u8], offset: usize, value: u64, little_endian: bool) -> Result<(), String> {
    let bytes = if little_endian {
        value.to_le_bytes()
    } else {
        value.to_be_bytes()
    };
    data.get_mut(offset..offset + 8)
        .ok_or_else(|| "truncated ELF data".to_string())?
        .copy_from_slice(&bytes);
    Ok(())
}

fn read_dynamic_entry(
    data: &[u8],
    offset: usize,
    layout: &Layout,
) -> Result<DynamicEntry, String> {
    if layout.is64 {
        let tag = read_u64(data, offset, layout.little_endian)? as i64;
        let value = read_u64(data, offset + 8, layout.little_endian)?;
        Ok(DynamicEntry { tag, value })
    } else {
        let tag = read_u32(data, offset, layout.little_endian)? as i32 as i64;
        let value = read_u32(data, offset + 4, layout.little_endian)? as u64;
        Ok(DynamicEntry { tag, value })
    }
}

fn write_dynamic_entry(
    data: &mut [u8],
    offset: usize,
    entry: &DynamicEntry,
    layout: &Layout,
) -> Result<(), String> {
    if layout.is64 {
        write_u64(data, offset, entry.tag as u64, layout.little_endian)?;
        write_u64(data, offset + 8, entry.value, layout.little_endian)
    } else {
        write_u32(data, offset, entry.tag as i32 as u32, layout.little_endian)?;
        write_u32(data, offset + 4, entry.value as u32, layout.little_endian)
    }
}

fn read_c_string(data: &[u8], offset: usize) -> Result<&[u8], String> {
    let tail = data
        .get(offset..)
        .ok_or_else(|| "string offset past end of ELF file".to_string())?;
    let end = tail
        .iter()
        .position(|byte| *byte == 0)
        .ok_or_else(|| "unterminated string in ELF file".to_string())?;
    Ok(&tail[..end])
}

fn parse_sections(data: &[u8], layout: &Layout) -> Result<Vec<Section>, String> {
    let (shoff, shentsize, shnum, shstrndx) = if layout.is64 {
        (
            read_u64(data, 40, layout.little_endian)?,
            read_u16(data, 58, layout.little_endian)? as usize,
            read_u16(data, 60, layout.little_endian)? as usize,
            read_u16(data, 62, layout.little_endian)? as usize,
        )
    } else {
        (
            read_u32(data, 32, layout.little_endian)? as u64,
            read_u16(data, 46, layout.little_endian)? as usize,
            read_u16(data, 48, layout.little_endian)? as usize,
            read_u16(data, 50, layout.little_endian)? as usize,
        )
    };
    if shoff == 0 || shnum == 0 {
        return Ok(Vec::new());
    }
    if shentsize < layout.section_header_size() || shstrndx >= shnum {
        return Err("invalid ELF section header table".to_string());
    }
    let table_start = shoff as usize;
    let table_end = table_start
        .checked_add(shnum * shentsize)
        .ok_or_else(|| "ELF section header table overflow".to_string())?;
    if table_end > data.len() {
        return Err("truncated ELF section header table".to_string());
    }

    let mut raw = Vec::with_capacity(shnum);
    for index in 0..shnum {
        let base = table_start + index * shentsize;
        let name = read_u32(data, base, layout.little_endian)?;
        let section_type = read_u32(data, base + 4, layout.little_endian)?;
        let (offset, size, entry_size) = if layout.is64 {
            (
                read_u64(data, base + 24, layout.little_endian)?,
                read_u64(data, base + 32, layout.little_endian)?,
                read_u64(data, base + 56, layout.little_endian)?,
            )
        } else {
            (
                read_u32(data, base + 16, layout.little_endian)? as u64,
                read_u32(data, base + 20, layout.little_endian)? as u64,
                read_u32(data, base + 36, layout.little_endian)? as u64,
            )
        };
        raw.push((name, section_type, offset, size, entry_size));
    }

    let names = raw[shstrndx];
    let names_end = names
        .2
        .checked_add(names.3)
        .ok_or_else(|| "ELF string table overflow".to_string())?
        as usize;
    if names_end > data.len() {
        return Err("truncated ELF section name table".to_string());
    }
    let mut sections = Vec::with_capacity(raw.len());
    for (name_offset, section_type, offset, size, entry_size) in raw {
        let name = read_c_string(data, names.2 as usize + name_offset as usize)?;
        sections.push(Section {
            name: String::from_utf8_lossy(name).to_string(),
            section_type,
            offset,
            size,
            entry_size,
        });
    }
    Ok(sections)
}

fn section_range(section: &Section) -> Result<(usize, usize), String> {
    let start = section.offset as usize;
    let end = start
        .checked_add(section.size as usize)
        .ok_or_else(|| "ELF section overflow".to_string())?;
    Ok((start, end))
}

fn find_section<'a>(sections: &'a [Section], name: &str) -> Option<&'a Section> {
    sections.iter().find(|section| section.name == name)
}

fn parse_dynamic(
    data: &[u8],
    section: &Section,
    layout: &Layout,
) -> Result<Vec<DynamicEntry>, String> {
    let entry_size = layout.dynamic_entry_size();
    let (start, end) = section_range(section)?;
    if end > data.len() {
        return Err("truncated ELF dynamic section".to_string());
    }
    let mut entries = Vec::new();
    let mut offset = start;
    while offset + entry_size <= end {
        let entry = read_dynamic_entry(data, offset, layout)?;
        let is_null = entry.tag == DT_NULL;
        entries.push(entry);
        if is_null {
            break;
        }
        offset += entry_size;
    }
    if entries.is_empty() {
        return Err("empty ELF dynamic section".to_string());
    }
    Ok(entries)
}

fn dynsym_strings(
    data: &[u8],
    dynsym: Option<&Section>,
    dynstr: &Section,
    layout: &Layout,
) -> Result<Vec<Vec<u8>>, String> {
    let Some(dynsym) = dynsym else {
        return Ok(Vec::new());
    };
    let (start, end) = section_range(dynsym)?;
    if end > data.len() || start > end {
        return Err("truncated ELF dynamic symbol table".to_string());
    }
    let entry_size = layout.dynsym_entry_size();
    let count = (end - start) / entry_size;
    let mut strings = Vec::with_capacity(count);
    for index in 0..count {
        let base = start + index * entry_size;
        let name = read_u32(data, base, layout.little_endian)?;
        let offset = dynstr
            .offset
            .checked_add(name as u64)
            .ok_or_else(|| "ELF dynamic string offset overflow".to_string())?
            as usize;
        strings.push(read_c_string(data, offset)?.to_vec());
    }
    Ok(strings)
}

fn rpath_entries(old_rpath: &[u8], remove: &[String], new_rpath: &[u8]) -> Vec<u8> {
    let mut result: Vec<Vec<u8>> = Vec::new();
    let mut push = |part: &[u8]| {
        if !result.iter().any(|existing| existing.as_slice() == part) {
            result.push(part.to_vec());
        }
    };
    if !new_rpath.is_empty() {
        for part in new_rpath.split(|byte| *byte == b':') {
            push(part);
        }
    }
    for part in old_rpath.split(|byte| *byte == b':') {
        if part.is_empty() {
            continue;
        }
        let removed = remove.iter().any(|entry| entry.as_bytes() == part);
        let padding = part.iter().all(|byte| *byte == b'X');
        if !removed && !padding {
            push(part);
        }
    }
    let mut joined = Vec::new();
    for (index, part) in result.iter().enumerate() {
        if index > 0 {
            joined.push(b':');
        }
        joined.extend_from_slice(part);
    }
    joined
}

fn remove_rpath_entry(
    data: &mut [u8],
    entries: &mut Vec<DynamicEntry>,
    index: usize,
    dynamic: &Section,
    dynstr: &Section,
    old_rpath: &[u8],
    dynsym_strings: &[Vec<u8>],
    layout: &Layout,
) -> Result<(), String> {
    let entry = entries[index].clone();
    let string_offset = dynstr
        .offset
        .checked_add(entry.value)
        .ok_or_else(|| "ELF rpath offset overflow".to_string())?
        as usize;
    let mut reused = 0;
    for string in dynsym_strings {
        if !string.is_empty() && old_rpath.ends_with(string) && string.len() > reused {
            reused = string.len();
        }
    }
    let prefix = old_rpath.len().saturating_sub(reused);
    let range_end = string_offset
        .checked_add(prefix)
        .ok_or_else(|| "ELF rpath offset overflow".to_string())?;
    let range = data
        .get_mut(string_offset..range_end)
        .ok_or_else(|| "ELF rpath string past end of file".to_string())?;
    for byte in range {
        *byte = b'X';
    }

    let mut removed = entries[index].clone();
    removed.tag = DT_NULL;
    let mut reordered = Vec::with_capacity(entries.len());
    reordered.extend_from_slice(&entries[..index]);
    reordered.extend_from_slice(&entries[index + 1..]);
    reordered.push(removed);
    for entry in &mut reordered[index..] {
        if entry.tag == DT_MIPS_RLD_MAP_REL {
            entry.value += 2 * (layout.word_size() as u64);
            break;
        }
    }
    *entries = reordered;

    let entry_size = layout.dynamic_entry_size();
    for (slot, entry) in entries.iter().enumerate() {
        write_dynamic_entry(data, dynamic.offset as usize + slot * entry_size, entry, layout)?;
    }
    Ok(())
}

fn rewrite_rpath_entries(
    data: &mut [u8],
    remove: &[String],
    new_rpath: &str,
    layout: &Layout,
    sections: &[Section],
) -> Result<(), String> {
    let Some(dynamic) = find_section(sections, ".dynamic") else {
        return Ok(());
    };
    let Some(dynstr) = find_section(sections, ".dynstr") else {
        return Ok(());
    };
    let dynsym = find_section(sections, ".dynsym");
    let mut entries = parse_dynamic(data, dynamic, layout)?;
    let strings = dynsym_strings(data, dynsym, dynstr, layout)?;

    for wanted in [DT_RPATH, DT_RUNPATH] {
        let Some(index) = entries.iter().position(|entry| entry.tag == wanted) else {
            continue;
        };
        let string_offset = dynstr
            .offset
            .checked_add(entries[index].value)
            .ok_or_else(|| "ELF rpath offset overflow".to_string())?
            as usize;
        let old_rpath = read_c_string(data, string_offset)?.to_vec();
        let combined = rpath_entries(&old_rpath, remove, new_rpath.as_bytes());
        if old_rpath.len() < combined.len() {
            return Err(format!(
                "New rpath must not be longer than the old one.\n Old: {}\n New: {}",
                String::from_utf8_lossy(&old_rpath),
                String::from_utf8_lossy(&combined)
            ));
        }
        if combined.is_empty() {
            remove_rpath_entry(
                data,
                &mut entries,
                index,
                dynamic,
                dynstr,
                &old_rpath,
                &strings,
                layout,
            )?;
        } else {
            let end = string_offset
                .checked_add(combined.len())
                .ok_or_else(|| "ELF rpath offset overflow".to_string())?;
            let range = data
                .get_mut(string_offset..end)
                .ok_or_else(|| "ELF rpath string past end of file".to_string())?;
            range.copy_from_slice(&combined);
            data.get_mut(end)
                .ok_or_else(|| "ELF rpath string past end of file".to_string())?
                .clone_from(&0);
        }
    }
    Ok(())
}

pub fn rewrite_rpath(data: &mut [u8], remove: &[String], new_rpath: &str) -> Result<(), String> {
    if data.len() < 4 || &data[0..4] != b"\x7fELF" {
        return Ok(());
    }
    let is64 = match data.get(4) {
        Some(1) => false,
        Some(2) => true,
        _ => return Err("unknown ELF class".to_string()),
    };
    let little_endian = match data.get(5) {
        Some(1) => true,
        Some(2) => false,
        _ => return Err("unknown ELF endianness".to_string()),
    };
    let layout = Layout {
        is64,
        little_endian,
    };
    let sections = parse_sections(data, &layout)?;
    if sections.is_empty() {
        return Ok(());
    }
    rewrite_rpath_entries(data, remove, new_rpath, &layout, &sections)
}

fn write_in_place(path: &Path, data: &[u8]) -> Result<(), String> {
    let open = || std::fs::OpenOptions::new().write(true).open(path);
    let mut file = match open() {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
            use std::os::unix::fs::PermissionsExt;
            let metadata = std::fs::metadata(path)
                .map_err(|e| format!("Cannot stat {}: {}", path.display(), e))?;
            let mode = metadata.permissions().mode();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode | 0o200))
                .map_err(|e| format!("Cannot make {} writable: {}", path.display(), e))?;
            let result = open().map_err(|e| format!("Cannot open {}: {}", path.display(), e));
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
                .map_err(|e| format!("Cannot restore mode on {}: {}", path.display(), e))?;
            result?
        }
        Err(error) => return Err(format!("Cannot open {}: {}", path.display(), error)),
    };
    file.write_all(data)
        .map_err(|e| format!("Cannot write {}: {}", path.display(), e))?;
    file.flush()
        .map_err(|e| format!("Cannot write {}: {}", path.display(), e))
}

pub fn fix_rpath(path: &Path, remove: &[String], new_rpath: &str) -> Result<(), String> {
    let mut data = std::fs::read(path)
        .map_err(|e| format!("Cannot read {}: {}", path.display(), e))?;
    if data.len() < 4 || &data[0..4] != b"\x7fELF" {
        return Ok(());
    }
    rewrite_rpath(&mut data, remove, new_rpath)?;
    write_in_place(path, &data)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn put_u16(data: &mut [u8], offset: usize, value: u16, little_endian: bool) {
        let bytes = if little_endian {
            value.to_le_bytes()
        } else {
            value.to_be_bytes()
        };
        data[offset..offset + 2].copy_from_slice(&bytes);
    }

    fn put_u32(data: &mut [u8], offset: usize, value: u32, little_endian: bool) {
        let bytes = if little_endian {
            value.to_le_bytes()
        } else {
            value.to_be_bytes()
        };
        data[offset..offset + 4].copy_from_slice(&bytes);
    }

    fn put_u64(data: &mut [u8], offset: usize, value: u64, little_endian: bool) {
        let bytes = if little_endian {
            value.to_le_bytes()
        } else {
            value.to_be_bytes()
        };
        data[offset..offset + 8].copy_from_slice(&bytes);
    }

    fn put_word(data: &mut [u8], offset: usize, value: u64, is64: bool, little_endian: bool) {
        if is64 {
            put_u64(data, offset, value, little_endian);
        } else {
            put_u32(data, offset, value as u32, little_endian);
        }
    }

    struct BuiltElf {
        data: Vec<u8>,
        dynstr_offset: usize,
        dynamic_offset: usize,
    }

    fn build_elf(
        is64: bool,
        little_endian: bool,
        dynstr: &[u8],
        entries: &[(i64, u64)],
        dynsym_name: u32,
    ) -> BuiltElf {
        let header_size = if is64 { 64 } else { 52 };
        let section_size = if is64 { 64 } else { 40 };
        let dyn_entry_size = if is64 { 16 } else { 8 };
        let dynsym_entry_size = if is64 { 24 } else { 16 };
        let shstrtab = b"\0.dynstr\0.dynamic\0.dynsym\0.shstrtab\0";
        let dynstr_name = 1u32;
        let dynamic_name = 9u32;
        let dynsym_name_offset = 18u32;
        let shstrtab_name = 26u32;

        let dynstr_offset = header_size;
        let dynsym_offset = dynstr_offset + dynstr.len();
        let dynamic_offset = dynsym_offset + dynsym_entry_size;
        let shstrtab_offset = dynamic_offset + entries.len() * dyn_entry_size;
        let shoff = shstrtab_offset + shstrtab.len();
        let shnum = 5usize;
        let total = shoff + shnum * section_size;
        let mut data = vec![0u8; total];

        data[0..4].copy_from_slice(b"\x7fELF");
        data[4] = if is64 { 2 } else { 1 };
        data[5] = if little_endian { 1 } else { 2 };
        data[6] = 1;
        put_u16(&mut data, 16, 3, little_endian);
        put_u16(&mut data, 18, if is64 { 62 } else { 3 }, little_endian);
        put_u32(&mut data, 20, 1, little_endian);
        put_word(&mut data, if is64 { 40 } else { 32 }, shoff as u64, is64, little_endian);
        put_u16(&mut data, if is64 { 52 } else { 40 }, header_size as u16, little_endian);
        put_u16(&mut data, if is64 { 58 } else { 46 }, section_size as u16, little_endian);
        put_u16(&mut data, if is64 { 60 } else { 48 }, shnum as u16, little_endian);
        put_u16(&mut data, if is64 { 62 } else { 50 }, 4, little_endian);

        data[dynstr_offset..dynstr_offset + dynstr.len()].copy_from_slice(dynstr);
        put_u32(&mut data, dynsym_offset, dynsym_name, little_endian);
        data[shstrtab_offset..shstrtab_offset + shstrtab.len()].copy_from_slice(shstrtab);
        for (index, (tag, value)) in entries.iter().enumerate() {
            let entry = DynamicEntry {
                tag: *tag,
                value: *value,
            };
            let layout = Layout {
                is64,
                little_endian,
            };
            write_dynamic_entry(&mut data, dynamic_offset + index * dyn_entry_size, &entry, &layout)
                .unwrap();
        }

        let write_section = |data: &mut Vec<u8>, index: usize, name: u32, section_type: u32, offset: usize, size: usize, entry_size: u64| {
            let base = shoff + index * section_size;
            put_u32(data, base, name, little_endian);
            put_u32(data, base + 4, section_type, little_endian);
            if is64 {
                put_u64(data, base + 24, offset as u64, little_endian);
                put_u64(data, base + 32, size as u64, little_endian);
                put_u64(data, base + 56, entry_size, little_endian);
            } else {
                put_u32(data, base + 16, offset as u32, little_endian);
                put_u32(data, base + 20, size as u32, little_endian);
                put_u32(data, base + 36, entry_size as u32, little_endian);
            }
        };
        write_section(&mut data, 1, dynstr_name, 3, dynstr_offset, dynstr.len(), 0);
        write_section(
            &mut data,
            2,
            dynamic_name,
            SHT_DYNAMIC,
            dynamic_offset,
            entries.len() * dyn_entry_size,
            dyn_entry_size as u64,
        );
        write_section(
            &mut data,
            3,
            dynsym_name_offset,
            11,
            dynsym_offset,
            dynsym_entry_size,
            dynsym_entry_size as u64,
        );
        write_section(
            &mut data,
            4,
            shstrtab_name,
            3,
            shstrtab_offset,
            shstrtab.len(),
            0,
        );

        BuiltElf {
            data,
            dynstr_offset,
            dynamic_offset,
        }
    }

    fn rpath_at(built: &BuiltElf, offset: usize) -> String {
        let start = built.dynstr_offset + offset;
        let end = built.data[start..]
            .iter()
            .position(|byte| *byte == 0)
            .unwrap()
            + start;
        String::from_utf8_lossy(&built.data[start..end]).to_string()
    }

    fn first_dynamic_tag(built: &BuiltElf, is64: bool, little_endian: bool) -> i64 {
        read_dynamic_entry(
            &built.data,
            built.dynamic_offset,
            &Layout {
                is64,
                little_endian,
            },
        )
        .unwrap()
        .tag
    }

    #[test]
    fn replaces_rpath_when_it_fits() {
        let old = b"\0/build/rpath\0";
        let remove = vec!["/build/rpath".to_string()];
        let mut built = build_elf(true, true, old, &[(DT_RUNPATH, 1), (DT_NULL, 0)], 0);
        rewrite_rpath(&mut built.data, &remove, "/install/lib").unwrap();
        assert_eq!(rpath_at(&built, 1), "/install/lib");
    }

    #[test]
    fn rejects_rpath_longer_than_old_space() {
        let old = b"\0/old\0";
        let mut built = build_elf(true, true, old, &[(DT_RUNPATH, 1), (DT_NULL, 0)], 0);
        let error = rewrite_rpath(&mut built.data, &[], "/a/much/longer/install/rpath").unwrap_err();
        assert!(error.contains("must not be longer"));
    }

    #[test]
    fn empty_result_removes_dynamic_entry() {
        let old = b"\0/build/lib:/usr/lib\0";
        let remove = vec!["/build/lib".to_string(), "/usr/lib".to_string()];
        let mut built = build_elf(true, true, old, &[(DT_RUNPATH, 1), (DT_NULL, 0)], 0);
        rewrite_rpath(&mut built.data, &remove, "").unwrap();
        assert_eq!(first_dynamic_tag(&built, true, true), DT_NULL);
        assert_eq!(rpath_at(&built, 1), "X".repeat(19));
    }

    #[test]
    fn keeps_entries_not_marked_for_removal() {
        let old = b"\0/build/lib:/usr/lib\0";
        let remove = vec!["/build/lib".to_string()];
        let mut built = build_elf(true, true, old, &[(DT_RUNPATH, 1), (DT_NULL, 0)], 0);
        rewrite_rpath(&mut built.data, &remove, "").unwrap();
        assert_eq!(rpath_at(&built, 1), "/usr/lib");
    }

    #[test]
    fn drops_padding_entries() {
        let old = b"\0$ORIGIN/:XXXX\0";
        let remove = vec!["$ORIGIN/".to_string()];
        let mut built = build_elf(true, true, old, &[(DT_RUNPATH, 1), (DT_NULL, 0)], 0);
        rewrite_rpath(&mut built.data, &remove, "").unwrap();
        assert_eq!(first_dynamic_tag(&built, true, true), DT_NULL);
    }

    #[test]
    fn preserves_dynsym_suffix_when_clearing_rpath() {
        let old = b"\0/old/keep\0keep\0";
        let keep_offset = 11u32;
        let remove = vec!["/old/keep".to_string()];
        let mut built = build_elf(
            true,
            true,
            old,
            &[(DT_RUNPATH, 1), (DT_NULL, 0)],
            keep_offset,
        );
        rewrite_rpath(&mut built.data, &remove, "").unwrap();
        assert_eq!(rpath_at(&built, 1), "XXXXXkeep");
    }

    #[test]
    fn rewrites_every_elf_class_and_endianness() {
        for is64 in [false, true] {
            for little_endian in [false, true] {
                let old = b"\0/old/rpath\0";
                let remove = vec!["/old/rpath".to_string()];
                let mut built = build_elf(
                    is64,
                    little_endian,
                    old,
                    &[(DT_RPATH, 1), (DT_NULL, 0)],
                    0,
                );
                rewrite_rpath(&mut built.data, &remove, "/new").unwrap();
                assert_eq!(
                    rpath_at(&built, 1),
                    "/new",
                    "64-bit={} little-endian={}",
                    is64,
                    little_endian
                );
            }
        }
    }

    #[test]
    fn ignores_non_elf_data() {
        let mut data = b"not an elf".to_vec();
        rewrite_rpath(&mut data, &[], "/lib").unwrap();
        assert_eq!(&data, b"not an elf");
    }
}
