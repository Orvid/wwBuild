module main;

import std.array : replace;
import std.algorithm : any;
import std.file;
import std.path;
import std.process : execute;
import std.stdio : writeln;
import std.string : endsWith;

import std.serialization : serializable, optional;
import std.serialization.json : fromJSON;

@serializable
struct Configuration
{
	string autodesk3DSMaxPath;
	string rootOutputDirectory;
}

@serializable 
struct BuildFile
{
	BuildConfiguration[] builds;
}

@serializable
struct BuildConfiguration
{
	string name;
	string output;
	@optional
	string outputRootDirectoryName;
	@optional
	string[] directories;
	@optional
	string[] includes;
	@optional
	string[] excludes;
	@optional
	string[] encrypted;
	@optional
	string[string] fileMap;
}

void main(string[] args)
{
	if (args.length < 3)
		DieError(`wwbuild "path_to_builds.json" build [build2] [build3] [...]`);

	string inputFile = absolutePath(args[1]);
	string[] configsToBuild = args[2..$];
	string rootDir = dirName(inputFile);

	if (configsToBuild.any!(c => c == "all") && configsToBuild.length > 1)
		DieError("Was told to build all configs, but additional configs were specified!");
	if (!exists(inputFile))
		DieError("Input file " ~ inputFile ~ " doesn't exist!");
	if (!exists(rootDir ~ "/wwbuild_config.json"))
		DieError("Expected config file at " ~ (rootDir ~ "/wwbuild_config.json") ~ " but it wasn't present!");

	Configuration config = fromJSON!Configuration(cast(string)read(rootDir ~ "/wwbuild_config.json"));
	BuildFile buildFile = fromJSON!BuildFile(cast(string)read(inputFile));

	foreach (b; buildFile.builds)
	{
		if (configsToBuild.any!(c => c == b.name || c == "all"))
		{
			writeln("Building config ", b.name);
			string unmappedBaseOutputPath = config.rootOutputDirectory ~ "/" ~ b.name;
			if (exists(unmappedBaseOutputPath))
				rmdirRecurse(unmappedBaseOutputPath);
			auto baseOutputPath = unmappedBaseOutputPath;
			if (b.outputRootDirectoryName)
				baseOutputPath ~= "/" ~ b.outputRootDirectoryName;
			mkdirRecurse(baseOutputPath);

			foreach (dir; b.directories)
			{
				mkdirRecurse(baseOutputPath ~ "/" ~ dir);

				foreach (ent; dirEntries(rootDir ~ "/" ~ dir, SpanMode.shallow))
				{
					auto normalEntName = buildNormalizedPath(ent.name);
					if (
						ent.isFile 
						&& !ent.name.endsWith(".mse") 
						&& !b.excludes.any!(e => normalEntName.endsWith(buildNormalizedPath(e))) 
						&& !b.encrypted.any!(e => normalEntName.endsWith(buildNormalizedPath(e)))
					)
					{
						copy(ent.name, baseOutputPath ~ "/" ~ dir ~ "/" ~ ent.name[(rootDir ~ "/" ~ dir).length..$]);
					}
				}
			}

			foreach (f; b.includes)
			{
				mkdirRecurse(dirName(baseOutputPath ~ "/" ~ f));
				copy(rootDir ~ "/" ~ f, baseOutputPath ~ "/" ~ f);
			}

			foreach (k, v; b.fileMap)
			{
				mkdirRecurse(dirName(unmappedBaseOutputPath ~ "/" ~ v));
				copy(rootDir ~ "/" ~ k, unmappedBaseOutputPath ~ "/" ~ v);
			}

			if (b.encrypted)
			{
				// Copy the encrypted files in so that we can replace references to the encrypted files.
				foreach (e; b.encrypted)
				{
					mkdirRecurse(dirName(baseOutputPath ~ "/" ~ e));
					copy(rootDir ~ "/" ~ e, baseOutputPath ~ "/" ~ e);
				}

				import std.regex : regex, replaceAll;
				__gshared searchRE = regex(`fileIn\s*\(\s*wallworm_installation_path\s*\+\s*"/WallWorm\.com(.+?)\.ms"\s*\)`, "");
				writeln("\tReplacing references to encrypted files...");
				foreach (ent; dirEntries(unmappedBaseOutputPath, SpanMode.breadth))
				{
					if (ent.isFile && ent.name.endsWith(".ms"))
					{
						string str = cast(string)read(ent.name);
						str = str.replaceAll!((m) {
							auto fName = buildNormalizedPath(m[1].replace("\\\\", "/") ~ ".ms")[1..$];
							if (b.encrypted.any!(e => fName == buildNormalizedPath(e)))
							{
								return `fileIn (wallworm_installation_path+"/WallWorm.com` ~ m[1] ~ `.mse")`;
							}
							return m[0];
						})(searchRE);
						write(ent.name, str);
					}
				}
				writeln("\tEncrypting files...");
				string mxCommand = "";
				foreach (e; b.encrypted)
					mxCommand ~= `encryptScript "` ~ (baseOutputPath.replace("\\", "/") ~ "/" ~ e) ~ `" version:1;`;
				execute([config.autodesk3DSMaxPath, "-q", "-silent", "-mip", "-mxs", mxCommand]);
				foreach (e; b.encrypted)
				{
					remove(baseOutputPath ~ "/" ~ e);
					if (b.excludes.any!(e2 => e2 == e))
					{
						remove(baseOutputPath ~ "/" ~ e ~ "e");
					}
				}
			}

			writeln("Done.");
		}
	}

	writeln("Complete.");
}


void DieError(string error)
{
	import core.stdc.stdlib : exit;
	writeln(error);
	exit(-1);
}