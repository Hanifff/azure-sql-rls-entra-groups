using System.Data;
using System.Text;
using Microsoft.Data.SqlClient;

// Minimal replacement for `sqlcmd -G`, so the demo has no system-level tooling
// dependency beyond the .NET SDK that building the Function Apps already needs.
//
//   sqlrunner <server.database.windows.net> <database> <file.sql> [more.sql ...]
//
// Reads the Entra access token from the SQL_ACCESS_TOKEN environment variable.
// Splits batches on GO, streams PRINT output, prints result sets, and exits
// non-zero if any batch throws - which is what lets deploy.sh gate on the
// verification and test scripts.

if (args.Length < 3)
{
    Console.Error.WriteLine("usage: sqlrunner <server> <database> <file.sql> [file.sql ...]");
    return 2;
}

var server   = args[0];
var database = args[1];
var files    = args.Skip(2).ToArray();

var token = Environment.GetEnvironmentVariable("SQL_ACCESS_TOKEN");
if (string.IsNullOrWhiteSpace(token))
{
    Console.Error.WriteLine("ERROR: SQL_ACCESS_TOKEN environment variable is not set.");
    return 2;
}

var connectionString = new SqlConnectionStringBuilder
{
    DataSource     = server,
    InitialCatalog = database,
    Encrypt        = true,
    ConnectTimeout = 60
}.ConnectionString;

foreach (var file in files)
{
    if (!File.Exists(file))
    {
        Console.Error.WriteLine($"ERROR: file not found: {file}");
        return 2;
    }

    Console.WriteLine();
    Console.WriteLine($"--- {Path.GetFileName(file)} " + new string('-', Math.Max(0, 60 - Path.GetFileName(file).Length)));

    await using var connection = new SqlConnection(connectionString) { AccessToken = token };
    connection.InfoMessage += (_, e) =>
    {
        foreach (SqlError err in e.Errors)
        {
            if (!string.IsNullOrWhiteSpace(err.Message)) Console.WriteLine(err.Message);
        }
    };

    try
    {
        await connection.OpenAsync();
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"ERROR: cannot connect to {server}/{database}: {ex.Message}");
        return 1;
    }

    var batchNumber = 0;
    foreach (var batch in SplitOnGo(await File.ReadAllTextAsync(file)))
    {
        batchNumber++;
        if (string.IsNullOrWhiteSpace(batch)) continue;

        try
        {
            await using var command = new SqlCommand(batch, connection) { CommandTimeout = 600 };
            await using var reader = await command.ExecuteReaderAsync();
            do
            {
                if (reader.FieldCount > 0) PrintResultSet(reader);
            }
            while (await reader.NextResultAsync());
        }
        catch (SqlException ex)
        {
            Console.Error.WriteLine();
            Console.Error.WriteLine($"ERROR in {Path.GetFileName(file)} (batch {batchNumber}): {ex.Message}");
            return 1;
        }
    }
}

Console.WriteLine();
return 0;

static void PrintResultSet(SqlDataReader reader)
{
    var widths = new int[reader.FieldCount];
    var rows = new List<string[]>();

    for (var i = 0; i < reader.FieldCount; i++) widths[i] = reader.GetName(i).Length;

    while (reader.Read())
    {
        var row = new string[reader.FieldCount];
        for (var i = 0; i < reader.FieldCount; i++)
        {
            row[i] = reader.IsDBNull(i) ? "NULL" : reader.GetValue(i)?.ToString() ?? "";
            if (row[i].Length > 60) row[i] = row[i][..57] + "...";
            widths[i] = Math.Max(widths[i], row[i].Length);
        }
        rows.Add(row);
    }

    if (rows.Count == 0) return;

    var header = new StringBuilder();
    var rule   = new StringBuilder();
    for (var i = 0; i < reader.FieldCount; i++)
    {
        header.Append(reader.GetName(i).PadRight(widths[i])).Append("  ");
        rule.Append(new string('-', widths[i])).Append("  ");
    }

    Console.WriteLine(header.ToString().TrimEnd());
    Console.WriteLine(rule.ToString().TrimEnd());

    foreach (var row in rows)
    {
        var line = new StringBuilder();
        for (var i = 0; i < row.Length; i++) line.Append(row[i].PadRight(widths[i])).Append("  ");
        Console.WriteLine(line.ToString().TrimEnd());
    }
    Console.WriteLine();
}

// Batch separator: a line consisting only of GO (case-insensitive).
static IEnumerable<string> SplitOnGo(string script)
{
    var batch = new StringBuilder();
    foreach (var line in script.Split('\n'))
    {
        if (line.Trim().Equals("GO", StringComparison.OrdinalIgnoreCase))
        {
            yield return batch.ToString();
            batch.Clear();
        }
        else
        {
            batch.AppendLine(line);
        }
    }
    if (batch.Length > 0) yield return batch.ToString();
}
