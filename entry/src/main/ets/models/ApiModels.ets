export interface TransferItem {
  id: string;
  transferId: string;
  kind: string;
  text?: string;
  name?: string;
  mimeType?: string;
  size?: number;
  sha256?: string;
}

export interface Transfer {
  id: string;
  sourceDeviceId: string;
  title?: string;
  status: string;
  createdAt: string;
  committedAt?: string;
  deletedAt?: string;
  items: TransferItem[];
}

export interface CreateTransferResponse {
  transfer: Transfer;
  missingBlobs: string[];
}

export interface TransferListResponse {
  transfers: Transfer[];
}

export interface Device {
  id: string;
  name: string;
  platform: string;
  syncMode: string;
  cursor: number;
  createdAt: string;
  lastSeenAt: string;
}

export interface PairResponse {
  device: Device;
  token: string;
}

export interface ErrorResponse {
  error: string;
}

export interface AppSettings {
  lanServerUrl: string;
  wanServerUrl: string;
  serverId: string;
  deviceToken: string;
}

export interface ServerInfo {
  serverId: string;
  protocolVersion: number;
}

export interface PeerSource {
  deviceId: string;
  deviceName: string;
  addresses: string[];
  ticket: string;
  expiresAt: string;
}

export interface PeerSourcesResponse {
  sources: PeerSource[];
}

export interface BlobDownloadResult {
  content: ArrayBuffer;
  route: string;
  sourceName?: string;
}

export interface LocalTransferFile {
  uri: string;
  name: string;
  mimeType: string;
  size: number;
  isImage: boolean;
}

export interface TransferInputContent {
  texts: string[];
  files: LocalTransferFile[];
  unsupportedCount: number;
}

export interface PreparedTransferFile extends LocalTransferFile {
  sha256: string;
}
