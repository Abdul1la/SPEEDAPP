/** An error with an HTTP status and a stable code the app can check. */
export class ApiError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export const badRequest = (code: string, message: string) =>
  new ApiError(400, code, message);
export const unauthorized = (message = 'Sign in first.') =>
  new ApiError(401, 'unauthorized', message);
export const forbidden = (code: string, message: string) =>
  new ApiError(403, code, message);
export const notFound = (message = 'Not found.') =>
  new ApiError(404, 'not_found', message);
export const conflict = (code: string, message: string) =>
  new ApiError(409, code, message);
export const tooMany = (message: string) =>
  new ApiError(429, 'rate_limited', message);
