export interface HubSpotSubmittedFormData {
  type: string;
  eventName: string;
  redirectUrl: string;
  conversionId: string;
  formGuid: string;
  submissionValues: {
    [key: string]: string;
  };
}
