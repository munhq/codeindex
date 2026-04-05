mod events;

pub use events::{CodeFileChanged, CodeIndexComplete};

use async_nats::jetstream;
use futures::StreamExt;
use tracing::error;

/// NATS sync layer for cross-pod code index invalidation.
pub struct NatsSyncLayer {
    js: jetstream::Context,
    project_id: String,
    pod_id: String,
}

impl NatsSyncLayer {
    pub async fn new(
        nats_url: &str,
        project_id: &str,
        pod_id: &str,
    ) -> Result<Self, async_nats::Error> {
        let client = async_nats::connect(nats_url).await?;
        let js = jetstream::new(client);

        // Create or get the stream
        let stream_name = format!("MUNBOT_{}", project_id.replace('-', "_").to_uppercase());
        let _ = js
            .create_stream(jetstream::stream::Config {
                name: stream_name.clone(),
                subjects: vec![
                    format!("munbot.{}.events.CodeFileChanged", project_id),
                    format!("munbot.{}.events.CodeIndexComplete", project_id),
                ],
                max_age: std::time::Duration::from_secs(7 * 24 * 3600),
                ..Default::default()
            })
            .await;

        Ok(Self {
            js,
            project_id: project_id.to_string(),
            pod_id: pod_id.to_string(),
        })
    }

    /// Publish a fileChanged event.
    pub async fn publish_file_changed(&self, event: &CodeFileChanged) -> Result<(), String> {
        let subject = format!("munbot.{}.events.CodeFileChanged", self.project_id);
        let payload = serde_json::to_vec(event).map_err(|e| e.to_string())?;
        let ack_future = self
            .js
            .publish(subject, payload.into())
            .await
            .map_err(|e| e.to_string())?;
        ack_future.await.map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Publish an IndexComplete event.
    pub async fn publish_index_complete(&self, event: &CodeIndexComplete) -> Result<(), String> {
        let subject = format!("munbot.{}.events.CodeIndexComplete", self.project_id);
        let payload = serde_json::to_vec(event).map_err(|e| e.to_string())?;
        let ack_future = self
            .js
            .publish(subject, payload.into())
            .await
            .map_err(|e| e.to_string())?;
        ack_future.await.map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Subscribe to file changed events from other pods.
    /// Returns a stream of events, filtering out own pod's events.
    pub async fn subscribe_file_changed(
        &self,
    ) -> Result<tokio::sync::mpsc::Receiver<CodeFileChanged>, String> {
        let subject = format!("munbot.{}.events.CodeFileChanged", self.project_id);
        let consumer_name = format!("munbot-{}-{}", self.project_id, self.pod_id);
        let pod_id = self.pod_id.clone();

        let stream_name =
            format!("MUNBOT_{}", self.project_id.replace('-', "_").to_uppercase());
        let stream = self
            .js
            .get_stream(stream_name)
            .await
            .map_err(|e| e.to_string())?;

        let consumer = stream
            .get_or_create_consumer(
                &consumer_name,
                jetstream::consumer::pull::Config {
                    durable_name: Some(consumer_name.clone()),
                    filter_subject: subject.clone(),
                    ..Default::default()
                },
            )
            .await
            .map_err(|e| e.to_string())?;

        let (tx, rx) = tokio::sync::mpsc::channel(256);

        tokio::spawn(async move {
            let mut messages = match consumer.messages().await {
                Ok(m) => m,
                Err(e) => {
                    error!("Failed to get message stream: {}", e);
                    return;
                }
            };
            while let Some(Ok(msg)) = messages.next().await {
                let event: CodeFileChanged = match serde_json::from_slice(&msg.payload) {
                    Ok(e) => e,
                    Err(e) => {
                        error!("Failed to deserialize CodeFileChanged: {}", e);
                        let _ = msg.ack().await;
                        continue;
                    }
                };

                // Skip own events
                if event.pod_id == pod_id {
                    let _ = msg.ack().await;
                    continue;
                }

                if tx.send(event).await.is_err() {
                    break;
                }
                let _ = msg.ack().await;
            }
        });

        Ok(rx)
    }
}
