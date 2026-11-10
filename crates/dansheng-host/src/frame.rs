//! Local IPC uses a big-endian u32 byte length followed by UTF-8 JSON.
use dansheng_core::{CoreError, CoreResult};
use serde::{Serialize, de::DeserializeOwned};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const MAX_FRAME: usize = 8 * 1024 * 1024;

pub async fn read_frame<R: AsyncRead + Unpin>(reader: &mut R) -> CoreResult<Vec<u8>> {
    let size = reader.read_u32().await? as usize;
    if size == 0 || size > MAX_FRAME {
        return Err(CoreError::new(
            "InvalidFrame",
            "frame length must be between 1 and 8 MiB",
        ));
    }
    let mut data = vec![0; size];
    reader.read_exact(&mut data).await?;
    Ok(data)
}

pub async fn read_json<R: AsyncRead + Unpin, T: DeserializeOwned>(reader: &mut R) -> CoreResult<T> {
    Ok(serde_json::from_slice(&read_frame(reader).await?)?)
}

pub async fn write_json<W: AsyncWrite + Unpin, T: Serialize>(
    writer: &mut W,
    value: &T,
) -> CoreResult<()> {
    let bytes = serde_json::to_vec(value)?;
    if bytes.is_empty() || bytes.len() > MAX_FRAME {
        return Err(CoreError::new("InvalidFrame", "response exceeds 8 MiB"));
    }
    writer.write_u32(bytes.len() as u32).await?;
    writer.write_all(&bytes).await?;
    writer.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn framing_rejects_empty_large_truncated_and_invalid_json() {
        for n in [0, MAX_FRAME as u32 + 1] {
            assert_eq!(
                read_frame(&mut &n.to_be_bytes()[..])
                    .await
                    .unwrap_err()
                    .code,
                "InvalidFrame"
            );
        }
        assert!(read_frame(&mut &[0, 0, 0, 3, 1][..]).await.is_err());
        assert!(
            read_json::<_, serde_json::Value>(&mut &[0, 0, 0, 1, b'{'][..])
                .await
                .is_err()
        );
        let mut bytes = vec![];
        write_json(&mut bytes, &serde_json::json!({"id":"roundtrip"}))
            .await
            .unwrap();
        assert_eq!(
            read_json::<_, serde_json::Value>(&mut bytes.as_slice())
                .await
                .unwrap()["id"],
            "roundtrip"
        );
    }
}
