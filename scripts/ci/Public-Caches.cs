using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;

namespace Dansheng.Ci
{
    // Keep the filesystem walk in managed code, without caching ancestor checks:
    // every destination entry still checks its complete current ancestor chain.
    public static class PublicDependencyCache
    {
        private static readonly string[,] Parts = {
            { "cargo-home/registry/cache", "cargo-home/registry/cache" },
            { "cargo-home/registry/index", "cargo-home/registry/index" },
            { "cargo-home/git/db", "cargo-home/git/db" },
            { "cargo-home/git/checkouts", "cargo-home/git/checkouts" },
            { "pub/hosted", "pub-cache/hosted" },
            { "pub/hosted-hashes", "pub-cache/hosted-hashes" },
            { "pub/git", "pub-cache/git" },
            { "gradle/caches", "gradle-cache/caches" },
            { "gradle/wrapper", "gradle-cache/wrapper" },
            { "gradle/native", "gradle-cache/native" }
        };
        private static readonly Regex Excluded = new Regex(
            @"^(credentials(?:\..*)?|config\.toml|\.npmrc|\.gitconfig|\.git-credentials|auth\.json|service\.json|gradle\.properties|init\.gradle(?:\.kts)?|.*\.(?:lock|lck|ci-tmp))$",
            RegexOptions.IgnoreCase);
        private static readonly StringComparison Comparison =
            Path.DirectorySeparatorChar == '\\' ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

        private static FileAttributes? Attributes(string path)
        {
            try { return File.GetAttributes(path); }
            catch (FileNotFoundException) { return null; }
            catch (DirectoryNotFoundException) { return null; }
        }

        private static string PlainPath(string path)
        {
            if (!Path.IsPathFullyQualified(path))
                throw new IOException("CI paths must be absolute.");
            string absolute = Path.GetFullPath(path);
            string full = absolute.TrimEnd('\\', '/');
            if (string.Equals(full, Path.GetPathRoot(absolute).TrimEnd('\\', '/'), Comparison))
                throw new IOException("A filesystem root is not a CI directory.");
            for (string cursor = full; !string.IsNullOrEmpty(cursor); cursor = Path.GetDirectoryName(cursor))
            {
                FileAttributes? attributes = Attributes(cursor);
                if (attributes.HasValue && (attributes.Value & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("CI runtime/cache paths must not contain links.");
            }
            return full;
        }

        private static bool Within(string child, string parent)
        {
            return child.StartsWith(parent + Path.DirectorySeparatorChar, Comparison);
        }

        public static int Sync(string sourceRoot, string destinationRoot, string direction, string[] seedKinds)
        {
            if (string.Equals(direction, "CacheToRuntime", StringComparison.OrdinalIgnoreCase)) direction = "CacheToRuntime";
            else if (string.Equals(direction, "RuntimeToCache", StringComparison.OrdinalIgnoreCase)) direction = "RuntimeToCache";
            else if (string.Equals(direction, "SeedToCache", StringComparison.OrdinalIgnoreCase)) direction = "SeedToCache";
            else
                throw new ArgumentException("Unsupported public cache direction.");
            bool seed = direction == "SeedToCache";
            var kinds = new HashSet<string>(seedKinds ?? Array.Empty<string>(), StringComparer.OrdinalIgnoreCase);
            foreach (string kind in kinds)
                if (!kind.Equals("Cargo", StringComparison.OrdinalIgnoreCase) &&
                    !kind.Equals("Pub", StringComparison.OrdinalIgnoreCase))
                    throw new ArgumentException("Unsupported public seed kind.");
            string source = PlainPath(sourceRoot);
            string destination = PlainPath(destinationRoot);
            if (source.Equals(destination, Comparison) || Within(source, destination) ||
                (!seed && Within(destination, source)))
                throw new IOException("Public cache source/destination overlap.");
            int copied = 0;
            for (int i = 0; i < Parts.GetLength(0); i++)
            {
                if (seed && !((kinds.Contains("Cargo") && i < 2) ||
                    (kinds.Contains("Pub") && (i == 4 || i == 5)))) continue;
                string fromPart = direction == "RuntimeToCache" ? Parts[i, 1] : Parts[i, 0];
                string toPart = direction == "CacheToRuntime" ? Parts[i, 1] : Parts[i, 0];
                string from = PlainPath(Path.Combine(source, fromPart));
                string toRoot = PlainPath(Path.Combine(destination, toPart));
                if (from.Equals(toRoot, Comparison) || Within(from, toRoot) || Within(toRoot, from))
                    throw new IOException("Public dependency trees overlap.");
                if (!Directory.Exists(from)) continue;
                var pending = new Stack<DirectoryInfo>();
                pending.Push(new DirectoryInfo(from));
                while (pending.Count != 0)
                {
                    foreach (FileSystemInfo item in pending.Pop().EnumerateFileSystemInfos())
                    {
                        FileAttributes attributes = item.Attributes;
                        if ((attributes & FileAttributes.ReparsePoint) != 0) continue;
                        string to = PlainPath(Path.Combine(toRoot, Path.GetRelativePath(from, item.FullName)));
                        if ((attributes & FileAttributes.Directory) != 0)
                        {
                            if (seed && (item.Name.Equals(".git", StringComparison.OrdinalIgnoreCase) ||
                                item.Name.Equals(".ssh", StringComparison.OrdinalIgnoreCase) ||
                                item.Name.Equals(".dart_tool", StringComparison.OrdinalIgnoreCase))) continue;
                            pending.Push((DirectoryInfo)item);
                            continue;
                        }
                        if (Excluded.IsMatch(item.Name) || Attributes(to).HasValue) continue;
                        Directory.CreateDirectory(Path.GetDirectoryName(to));
                        string temporary = to + "." + Guid.NewGuid().ToString("N") + ".ci-tmp";
                        try
                        {
                            File.Copy(item.FullName, temporary, false);
                            try { File.Move(temporary, to, false); copied++; }
                            catch (IOException)
                            {
                                // A concurrent immutable dependency publisher may win.
                                // Recheck links too; a link must never count as success.
                                PlainPath(to);
                                if (!File.Exists(to)) throw;
                            }
                        }
                        finally { if (File.Exists(temporary)) File.Delete(temporary); }
                    }
                }
            }
            return copied;
        }
    }
}
