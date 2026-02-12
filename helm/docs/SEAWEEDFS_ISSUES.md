# SeaweedFS Issues with Hadoop S3A

Known issues discovered during Starlake Helm chart development when using SeaweedFS as the S3-compatible object storage backend with Hadoop S3A connector.

## 1. 86-Byte Directory Marker Bug

### Symptom

Empty S3 directories appear as 86-byte files in Starlake UI file listings. For example, creating a new domain with subdirectories results in entries showing 86 bytes instead of 0 bytes. This causes incorrect file counts and confusing directory displays.

### Root Cause

When Hadoop S3A creates 0-byte directory markers via `PUT` over HTTP (not HTTPS), the AWS SDK 1.x uses chunked transfer encoding with AWS V4 signature. The chunk terminator has the format:

```
0;chunk-signature=<64-hex-chars>\r\n\r\n
```

This terminator is exactly **86 bytes** (`2 + 1 + 16 + 1 + 64 + 2 + 2 = 88` characters, but 86 bytes of meaningful payload). SeaweedFS stores this terminator as actual file content instead of recognizing and discarding it as a transfer encoding artifact.

The obvious fix would be to disable chunked transfer encoding via `fs.s3a.payload.signing.enabled=false`. However, this property was only introduced in **Hadoop 3.3.5** ([HADOOP-17936](https://issues.apache.org/jira/browse/HADOOP-17936)). Starlake ships Hadoop 3.3.4 (`hadoop-aws-3.3.4.jar`), where this property does not exist.

### Fix

Force S3 V2 signing (the legacy signing algorithm), which does not use chunked transfer encoding at all:

```
fs.s3a.signing-algorithm=S3SignerType
```

This is safe for SeaweedFS since it supports both V2 and V4 signing. The V2 signer sends the full payload in a single request body, avoiding the chunked encoding problem entirely.

### Configuration

In `SL_STORAGE_CONF` (environment variable passed to Starlake API):

```
fs.s3a.signing-algorithm=S3SignerType,fs.s3a.path.style.access=true,fs.s3a.connection.ssl.enabled=false,...
```

In `core-site.xml` (used by Spark/Hadoop jobs):

```xml
<property>
  <name>fs.s3a.signing-algorithm</name>
  <value>S3SignerType</value>
</property>
```

In `spark-defaults.conf`:

```
spark.hadoop.fs.s3a.signing-algorithm S3SignerType
```

### Why DuckLake Is Not Affected

DuckLake (DuckDB) uses its own S3 client (`httpfs` extension), not Hadoop S3A. Key differences:

| | Hadoop S3A | DuckLake (DuckDB httpfs) |
|---|---|---|
| Directory markers | Explicit 0-byte objects with trailing `/` | None -- directories are implicit S3 prefixes |
| HTTP client | AWS SDK 1.x with chunked V4 signing | Native HTTP with `Content-Length: 0` |
| Bug exposure | Yes (before fix) | Never |

DuckLake writes parquet files directly (e.g., `test_s3/v2test/orders/ducklake-UUID.parquet`). The "directory" `orders/` is just a key prefix -- no `PUT` of a 0-byte marker object, no chunked encoding, no bug.

### Verification

After applying the fix, all newly created directory markers are 0 bytes. New domains show correct file counts in Starlake UI. Existing 86-byte markers from before the fix remain and must be cleaned up manually if needed (`aws s3 rm` and recreate).

## 2. Filer 404 on S3-Created Directories

### Symptom

Parent directory listing in SeaweedFS Filer UI (`http://localhost:8888`) shows directories exist, but navigating into them returns HTTP 404.

### Root Cause

Known SeaweedFS bugs related to S3/Filer directory synchronization:

- **[Issue #5193](https://github.com/seaweedfs/seaweedfs/issues/5193)**: Unable to list objects with prefix ending with `/`. The Filer does not always materialize implicit S3 directories as browsable Filer entries.
- **[Issue #6113](https://github.com/seaweedfs/seaweedfs/issues/6113)**: Directories disappear in Filer Store due to race condition (42% reproduction rate in reported tests). Concurrent Filer operations can delete parent directory entries even when children still exist.
- **[PR #7826](https://github.com/seaweedfs/seaweedfs/pull/7826)**: Changes to implicit directory handling for S3 client compatibility. This PR adjusts how directories created implicitly via S3 API are surfaced in the Filer.

### Impact

**Cosmetic only.** Starlake uses the S3 API for all data operations, which works correctly regardless of Filer state. The Filer UI is only an admin browsing tool. S3 API commands (`aws s3 ls`, `aws s3 cp`, etc.) always return correct results.

### Workaround

Use S3 API tools instead of the Filer web UI for directory inspection:

```bash
# List bucket contents
aws s3 ls s3://starlake/ --endpoint-url http://localhost:8333 --recursive

# List specific prefix
aws s3 ls s3://starlake/my-domain/ --endpoint-url http://localhost:8333
```

### Status

Unresolved upstream bugs. Not blocking for Starlake operations.

## 3. Recommended S3A Configuration for SeaweedFS

Full configuration with rationale for each property. All properties are set in both `core-site.xml` and `spark-defaults.conf` (with `spark.hadoop.` prefix) in the Helm chart.

### Properties

| Property | Value | Rationale |
|----------|-------|-----------|
| `fs.s3a.signing-algorithm` | `S3SignerType` | Use S3 V2 signing. Avoids V4 chunked encoding that produces 86-byte directory markers (see section 1). |
| `fs.s3a.path.style.access` | `true` | Required for non-AWS S3 backends. Uses `http://host/bucket/key` instead of `http://bucket.host/key`. |
| `fs.s3a.connection.ssl.enabled` | `false` | SeaweedFS uses HTTP internally in Kubernetes. No TLS termination at the S3 API level. |
| `fs.s3a.directory.marker.retention` | `keep` | Do not delete directory markers after file creation. SeaweedFS manages directories natively via its Filer layer. Deleting markers can cause empty directories to disappear. [SeaweedFS wiki recommendation](https://github.com/seaweedfs/seaweedfs/wiki/HDFS-via-S3-connector). |
| `fs.s3a.multiobjectdelete.enable` | `false` | Disable multi-object delete API. Behavior is unreliable on non-AWS S3 backends and can cause partial deletions. [SeaweedFS wiki recommendation](https://github.com/seaweedfs/seaweedfs/wiki/HDFS-via-S3-connector). |
| `fs.s3a.change.detection.mode` | `warn` | Log a warning instead of throwing an exception when file modification is detected during read. SeaweedFS does not support ETags the same way as AWS S3. |
| `fs.s3a.change.detection.version.required` | `false` | Do not require version IDs for change detection. SeaweedFS does not support S3 object versioning by default. |
| `fs.s3a.bucket.probe` | `0` | Skip `HEAD` bucket check on startup. Faster initialization; avoids 403/404 errors if credentials or bucket don't exist yet. |

### Example core-site.xml

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property>
    <name>fs.s3a.endpoint</name>
    <value>http://starlake-seaweedfs:8333</value>
  </property>
  <property>
    <name>fs.s3a.path.style.access</name>
    <value>true</value>
  </property>
  <property>
    <name>fs.s3a.connection.ssl.enabled</name>
    <value>false</value>
  </property>
  <property>
    <name>fs.s3a.impl</name>
    <value>org.apache.hadoop.fs.s3a.S3AFileSystem</value>
  </property>
  <property>
    <name>fs.s3a.access.key</name>
    <value>seaweedfs</value>
  </property>
  <property>
    <name>fs.s3a.secret.key</name>
    <value>seaweedfs123</value>
  </property>
  <property>
    <name>fs.s3a.signing-algorithm</name>
    <value>S3SignerType</value>
  </property>
  <property>
    <name>fs.s3a.bucket.probe</name>
    <value>0</value>
  </property>
  <property>
    <name>fs.s3a.directory.marker.retention</name>
    <value>keep</value>
  </property>
  <property>
    <name>fs.s3a.multiobjectdelete.enable</name>
    <value>false</value>
  </property>
  <property>
    <name>fs.s3a.change.detection.mode</name>
    <value>warn</value>
  </property>
  <property>
    <name>fs.s3a.change.detection.version.required</name>
    <value>false</value>
  </property>
</configuration>
```

### Example spark-defaults.conf

```
spark.hadoop.fs.s3a.endpoint http://starlake-seaweedfs:8333
spark.hadoop.fs.s3a.path.style.access true
spark.hadoop.fs.s3a.connection.ssl.enabled false
spark.hadoop.fs.s3a.impl org.apache.hadoop.fs.s3a.S3AFileSystem
spark.hadoop.fs.s3a.access.key seaweedfs
spark.hadoop.fs.s3a.secret.key seaweedfs123
spark.hadoop.fs.s3a.signing-algorithm S3SignerType
spark.hadoop.fs.s3a.bucket.probe 0
spark.hadoop.fs.s3a.directory.marker.retention keep
spark.hadoop.fs.s3a.multiobjectdelete.enable false
spark.hadoop.fs.s3a.change.detection.mode warn
spark.hadoop.fs.s3a.change.detection.version.required false
```

## References

- [SeaweedFS Wiki: HDFS via S3 connector](https://github.com/seaweedfs/seaweedfs/wiki/HDFS-via-S3-connector) -- official configuration guidance for Hadoop S3A with SeaweedFS
- [HADOOP-17936](https://issues.apache.org/jira/browse/HADOOP-17936) -- `fs.s3a.payload.signing.enabled` introduced in Hadoop 3.3.5
- [SeaweedFS #5193](https://github.com/seaweedfs/seaweedfs/issues/5193) -- unable to list objects with prefix ending with "/"
- [SeaweedFS #6113](https://github.com/seaweedfs/seaweedfs/issues/6113) -- directories disappear in Filer Store (race condition)
- [SeaweedFS #7826](https://github.com/seaweedfs/seaweedfs/pull/7826) -- implicit directory handling for S3 compatibility
- Helm chart implementation: `helm/starlake/templates/seaweedfs/hadoop-config.yaml`
