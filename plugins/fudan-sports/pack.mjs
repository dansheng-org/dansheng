// SPDX-License-Identifier: GPL-3.0-or-later
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { resolve, dirname, basename, join } from 'node:path';
import { createHash } from 'node:crypto';
import { deflateRawSync } from 'node:zlib';

const DOS_TIME = 0x0000; // 00:00:00
const DOS_DATE = ((2026 - 1980) << 9) | (1 << 5) | 1; // 2026-01-01 (0x5c21)

// Standard CRC-32 table
const CRC_TABLE = new Uint32Array(256);
for (let i = 0; i < 256; i++) {
  let c = i;
  for (let k = 0; k < 8; k++) {
    c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
  }
  CRC_TABLE[i] = c >>> 0;
}

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  }
  return ((c ^ 0xffffffff) >>> 0);
}

/**
 * Deterministically packs runtime assets into a .dspack ZIP archive.
 * Flat layout with manifest.json at the root, sorted entries, fixed timestamps.
 */
export function buildDeterministicZip(files) {
  // Sort files by path for deterministic entry order
  const sortedNames = Object.keys(files).sort();
  const localChunks = [];
  const cdChunks = [];
  let offset = 0;

  for (const name of sortedNames) {
    const rawData = files[name];
    const dataBuf = Buffer.isBuffer(rawData) ? rawData : Buffer.from(rawData);
    const uncompressedSize = dataBuf.length;
    const fileCrc = crc32(dataBuf);
    const compressedBuf = deflateRawSync(dataBuf, { level: 9 });
    const compressedSize = compressedBuf.length;
    const nameBuf = Buffer.from(name, 'utf8');

    // Local file header (30 bytes + nameBuf.length)
    const localHeader = Buffer.alloc(30);
    localHeader.writeUInt32LE(0x04034b50, 0); // local file header signature
    localHeader.writeUInt16LE(20, 4);         // version needed to extract (2.0)
    localHeader.writeUInt16LE(0x0800, 6);     // general purpose bit flag (bit 11 = UTF-8)
    localHeader.writeUInt16LE(8, 8);          // compression method (8 = Deflate)
    localHeader.writeUInt16LE(DOS_TIME, 10);  // last mod file time
    localHeader.writeUInt16LE(DOS_DATE, 12);  // last mod file date
    localHeader.writeUInt32LE(fileCrc, 14);   // crc-32
    localHeader.writeUInt32LE(compressedSize, 18); // compressed size
    localHeader.writeUInt32LE(uncompressedSize, 22); // uncompressed size
    localHeader.writeUInt16LE(nameBuf.length, 26);   // file name length
    localHeader.writeUInt16LE(0, 28);         // extra field length

    const localEntry = Buffer.concat([localHeader, nameBuf, compressedBuf]);
    localChunks.push(localEntry);

    // Central directory header (46 bytes + nameBuf.length)
    const cdHeader = Buffer.alloc(46);
    cdHeader.writeUInt32LE(0x02014b50, 0);   // central file header signature
    cdHeader.writeUInt16LE((0 << 8) | 20, 4); // version made by (DOS / FAT, 2.0)
    cdHeader.writeUInt16LE(20, 6);           // version needed to extract (2.0)
    cdHeader.writeUInt16LE(0x0800, 8);       // general purpose bit flag
    cdHeader.writeUInt16LE(8, 10);           // compression method
    cdHeader.writeUInt16LE(DOS_TIME, 12);    // last mod file time
    cdHeader.writeUInt16LE(DOS_DATE, 14);    // last mod file date
    cdHeader.writeUInt32LE(fileCrc, 16);     // crc-32
    cdHeader.writeUInt32LE(compressedSize, 20); // compressed size
    cdHeader.writeUInt32LE(uncompressedSize, 24); // uncompressed size
    cdHeader.writeUInt16LE(nameBuf.length, 28);   // file name length
    cdHeader.writeUInt16LE(0, 30);           // extra field length
    cdHeader.writeUInt16LE(0, 32);           // file comment length
    cdHeader.writeUInt16LE(0, 34);           // disk number start
    cdHeader.writeUInt16LE(0, 36);           // internal file attributes
    cdHeader.writeUInt32LE(0, 38);           // external file attributes
    cdHeader.writeUInt32LE(offset, 42);      // relative offset of local header

    const cdEntry = Buffer.concat([cdHeader, nameBuf]);
    cdChunks.push(cdEntry);

    offset += localEntry.length;
  }

  const centralDirectoryOffset = offset;
  const centralDirectoryBuf = Buffer.concat(cdChunks);
  const centralDirectorySize = centralDirectoryBuf.length;

  // End of central directory record (22 bytes)
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);                 // end of central dir signature
  eocd.writeUInt16LE(0, 4);                          // number of this disk
  eocd.writeUInt16LE(0, 6);                          // number of the disk with start of central directory
  eocd.writeUInt16LE(sortedNames.length, 8);         // total number of entries on this disk
  eocd.writeUInt16LE(sortedNames.length, 10);        // total number of entries
  eocd.writeUInt32LE(centralDirectorySize, 12);      // size of central directory
  eocd.writeUInt32LE(centralDirectoryOffset, 16);    // offset of start of central directory
  eocd.writeUInt16LE(0, 20);                         // .ZIP file comment length

  return Buffer.concat([...localChunks, centralDirectoryBuf, eocd]);
}

/**
 * Pack official.fudan-sports runtime assets into a .dspack ZIP.
 */
export function pack(targetPath) {
  const pluginDir = dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
  const repoRoot = resolve(pluginDir, '../..');

  const outputPath = targetPath
    ? resolve(targetPath)
    : resolve(repoRoot, '.local/plugins/official.fudan-sports-0.2.0.dspack');

  const filesToPack = [
    'manifest.json',
    'main.mjs',
    'api.mjs',
    'policy.mjs',
    'host-policy.json',
    'platform-support.json',
    'types.d.ts',
    'README.md',
    'NOTICE.md',
  ];

  const fileMap = {};
  for (const f of filesToPack) {
    const fullPath = join(pluginDir, f);
    if (!existsSync(fullPath)) {
      throw new Error(`Required runtime asset missing: ${fullPath}`);
    }
    fileMap[f] = readFileSync(fullPath);
  }

  fileMap.LICENSE = readFileSync(join(repoRoot,'LICENSE'));
  const zipBytes = buildDeterministicZip(fileMap);
  const sha256 = createHash('sha256').update(zipBytes).digest('hex');

  mkdirSync(dirname(outputPath), { recursive: true });
  writeFileSync(outputPath, zipBytes);

  return {
    outputPath,
    sha256,
    byteLength: zipBytes.length,
    entryCount: Object.keys(fileMap).length,
    entries: Object.keys(fileMap).sort(),
  };
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'))) {
  try {
    const result = pack(process.argv[2]);
    console.log(`Successfully built deterministic package:`);
    console.log(`  Path: ${result.outputPath}`);
    console.log(`  SHA-256: ${result.sha256}`);
    console.log(`  Size: ${result.byteLength} bytes`);
    console.log(`  Entries (${result.entryCount}): ${result.entries.join(', ')}`);
  } catch (err) {
    console.error('Packaging failed:', err);
    process.exit(1);
  }
}
