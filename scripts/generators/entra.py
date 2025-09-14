#!/usr/bin/env python3
"""
Microsoft Entra ID Test Data Manager

This script can generate realistic test data for load testing Entra ID sync functionality
and clean up test data using cleanup tags. It creates users, groups, nested group
hierarchies, and memberships while avoiding cycles.
"""

import requests
import time
import random
import logging
import argparse
import sys
from typing import List, Dict, Set, Optional
from dataclasses import dataclass
from faker import Faker
import numpy as np
import urllib.parse
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[
        logging.FileHandler("entra_test_manager.log"),
        logging.StreamHandler(sys.stdout),
    ],
)
logger = logging.getLogger(__name__)


@dataclass
class EntraConfig:
    """Configuration for Entra ID connection"""

    tenant_id: str
    client_id: str
    client_secret: str
    tenant_domain: Optional[str] = None


@dataclass
class GenerationConfig:
    """Configuration for data generation"""

    total_groups: int
    total_users: int
    avg_subgroups_per_group: float
    avg_users_per_group: float
    max_hierarchy_depth: int = 5
    batch_size: int = 20
    max_retries: int = 5


class EntraTestManager:
    def __init__(
        self,
        entra_config: EntraConfig,
        generation_config: Optional[GenerationConfig] = None,
    ):
        self.entra_config = entra_config
        self.generation_config = generation_config
        self.fake = Faker()
        self.access_token: Optional[str] = None
        self.token_expires_at: Optional[float] = None
        self.rate_limit_until: Optional[float] = None  # Global rate limit tracking
        self.created_users: List[Dict] = []
        self.created_groups: List[Dict] = []
        self.group_hierarchy: Dict[str, List[str]] = {}  # parent_id -> [child_ids]
        self.session = self._create_session_with_retry()
        # Generate unique cleanup tag for this run (max 16 chars for employeeId)
        # Format: "LT" + timestamp last 8 digits + 4 random digits = 14 chars total
        timestamp_short = str(int(time.time()))[-8:]
        self.cleanup_tag = f"LT{timestamp_short}{random.randint(1000, 9999)}"

    def _create_session_with_retry(self) -> requests.Session:
        """Create a requests session with automatic retry logic for rate limiting"""
        session = requests.Session()
        
        # Configure retry strategy for 429 (Too Many Requests) and server errors
        # The Retry class will automatically handle Retry-After headers when respect_retry_after_header=True
        retry_strategy = Retry(
            total=self.generation_config.max_retries if self.generation_config else 5,
            status_forcelist=[429, 503, 504],  # Retry on rate limit and server errors
            allowed_methods=["HEAD", "GET", "PUT", "DELETE", "OPTIONS", "TRACE", "POST"],
            backoff_factor=1,  # Used when no Retry-After header: 1, 2, 4, 8, 16 seconds
            respect_retry_after_header=True,  # Will sleep for the time specified in Retry-After header
            raise_on_status=False  # Don't raise exception, let us handle it
        )
        
        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("http://", adapter)
        session.mount("https://", adapter)
        
        # Add hook to log when we hit rate limits
        original_send = adapter.send
        
        def send_with_logging(request, **kwargs):
            response = original_send(request, **kwargs)
            if response.status_code == 429:
                retry_after = response.headers.get('Retry-After', 'not specified')
                logger.info(f"Rate limited (429). Server says Retry-After: {retry_after} seconds. Retrying automatically...")
            return response
        
        adapter.send = send_with_logging
        
        return session

    def get_access_token(self) -> str:
        """Get OAuth2 access token for Microsoft Graph API"""
        logger.info("Obtaining access token...")

        token_url = f"https://login.microsoftonline.com/{self.entra_config.tenant_id}/oauth2/v2.0/token"

        data = {
            "client_id": self.entra_config.client_id,
            "client_secret": self.entra_config.client_secret,
            "scope": "https://graph.microsoft.com/.default",
            "grant_type": "client_credentials",
        }

        try:
            response = self.session.post(token_url, data=data)
            response.raise_for_status()
            token_data = response.json()
            self.access_token = token_data["access_token"]
            # Token expires_in is in seconds, typically 3600 (1 hour)
            # Set expiry time with 5 minute buffer for safety
            expires_in = token_data.get("expires_in", 3600)
            self.token_expires_at = time.time() + expires_in - 300  # 5 min buffer
            logger.info(f"Access token obtained successfully (expires in {expires_in} seconds)")
            return self.access_token
        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to get access token: {e}")
            raise

    def get_headers(self) -> Dict[str, str]:
        """Get HTTP headers for Graph API requests"""
        # Check if token needs refresh
        if not self.access_token or (self.token_expires_at and time.time() >= self.token_expires_at):
            if self.token_expires_at and time.time() >= self.token_expires_at:
                logger.info("Access token expired, refreshing...")
            self.get_access_token()

        return {
            "Authorization": f"Bearer {self.access_token}",
            "Content-Type": "application/json",
        }
    
    def _wait_for_rate_limit(self):
        """Wait if we're currently rate limited"""
        if self.rate_limit_until and time.time() < self.rate_limit_until:
            wait_time = self.rate_limit_until - time.time()
            if wait_time > 0:
                logger.info(f"Rate limited globally. Waiting {wait_time:.1f} seconds...")
                time.sleep(wait_time)
    
    def _handle_rate_limit_response(self, response: requests.Response):
        """Update global rate limit tracking based on response"""
        if response.status_code == 429:
            retry_after = response.headers.get('Retry-After')
            if retry_after:
                try:
                    # Retry-After can be in seconds or an HTTP date
                    wait_seconds = int(retry_after)
                    self.rate_limit_until = time.time() + wait_seconds
                    logger.warning(f"Rate limited (429). Setting global pause for {wait_seconds} seconds")
                except ValueError:
                    # If it's not an integer, it might be a date - default to 150 seconds
                    self.rate_limit_until = time.time() + 150
                    logger.warning(f"Rate limited (429). Setting global pause for 150 seconds (default)")
            else:
                # No Retry-After header, use default
                self.rate_limit_until = time.time() + 150
                logger.warning(f"Rate limited (429) without Retry-After header. Using 150 seconds default")
    
    def _make_api_request(self, method: str, url: str, **kwargs) -> requests.Response:
        """Make an API request with automatic 401 handling and rate limit checking"""
        # Wait if we're globally rate limited
        self._wait_for_rate_limit()
        
        headers = kwargs.pop('headers', {})
        headers.update(self.get_headers())
        
        response = self.session.request(method, url, headers=headers, **kwargs)
        
        # Handle rate limiting
        if response.status_code == 429:
            self._handle_rate_limit_response(response)
            self._wait_for_rate_limit()
            # Retry after waiting
            response = self.session.request(method, url, headers=headers, **kwargs)
        
        # Handle 401 - token expired
        if response.status_code == 401:
            logger.info("Got 401, refreshing access token...")
            self.access_token = None  # Force token refresh
            headers.update(self.get_headers())
            response = self.session.request(method, url, headers=headers, **kwargs)
        
        return response

    # ============================================================================
    # GENERATION METHODS
    # ============================================================================

    def generate_fake_user_data(self, index: int, cleanup_tag: str) -> Dict:
        """Generate realistic fake user data"""
        first_name = self.fake.first_name()
        last_name = self.fake.last_name()
        # Include cleanup tag in the username to ensure uniqueness across runs
        unique_username = f"u{cleanup_tag}{index:06d}"
        
        return {
            "displayName": f"{first_name} {last_name}",
            "givenName": first_name,
            "surname": last_name,
            "mailNickname": unique_username,
            "userPrincipalName": f"{unique_username}@{self.entra_config.tenant_domain}",
            "passwordProfile": {
                "password": "TempPassword123!",
                "forceChangePasswordNextSignIn": False,
            },
            "accountEnabled": True,
            "jobTitle": self.fake.job(),
            "department": random.choice(
                [
                    "Engineering",
                    "Sales",
                    "Marketing",
                    "HR",
                    "Finance",
                    "Operations",
                    "IT",
                    "Legal",
                    "Product",
                    "Support",
                ]
            ),
            "officeLocation": random.choice(
                [
                    "New York",
                    "San Francisco",
                    "London",
                    "Tokyo",
                    "Sydney",
                    "Berlin",
                    "Toronto",
                    "Austin",
                    "Seattle",
                    "Boston",
                ]
            ),
            # Use employeeId for tagging (searchable field, max 16 chars)
            "employeeId": cleanup_tag,
        }

    def generate_fake_group_data(
        self, index: int, parent_group: Optional[str] = None, cleanup_tag: str = None
    ) -> Dict:
        """Generate realistic fake group data"""
        departments = [
            "Engineering",
            "Sales",
            "Marketing",
            "HR",
            "Finance",
            "Operations",
            "IT",
        ]
        roles = [
            "Managers",
            "Leads",
            "Analysts",
            "Specialists",
            "Interns",
            "Contractors",
        ]
        locations = ["US", "EU", "APAC", "Americas", "Global"]

        # Generate a unique cleanup tag if not provided
        if not cleanup_tag:
            cleanup_tag = f"LoadTest-{int(time.time())}"

        if parent_group:
            # Generate subgroup names that relate to parent
            group_types = [
                f"{random.choice(roles)}",
                f"{random.choice(locations)} Team",
                f"Project {self.fake.word().title()}",
                f"{random.choice(['Senior', 'Junior', 'Lead'])} {random.choice(roles)}",
            ]
            name_suffix = random.choice(group_types)
            base_name = f"TestGroup{index:04d} {name_suffix}"
        else:
            # Generate top-level group names
            base_name = f"TestGroup{index:04d} {random.choice(departments)}"

        # Include cleanup tag in displayName for better filtering
        display_name = f"TEST-{cleanup_tag}-{base_name}"
        
        # Include cleanup tag in mailNickname for uniqueness
        unique_group_nickname = f"g{cleanup_tag}{index:06d}"
        
        return {
            "displayName": display_name,
            "mailNickname": unique_group_nickname,
            "description": f"Test group for load testing - {self.fake.catch_phrase()}",
            "groupTypes": [],
            "securityEnabled": True,
            "mailEnabled": False,
        }

    def create_users_batch(self, user_data_list: List[Dict]) -> List[Dict]:
        """Create users in batch using Graph API batch endpoint"""
        if not user_data_list:
            return []

        # Check tenant domain is set
        if not self.entra_config.tenant_domain:
            logger.error("Tenant domain is required for user creation!")
            logger.error("Please provide --tenant-domain parameter")
            return []

        # Prepare batch request
        requests_data = []
        for i, user_data in enumerate(user_data_list):
            requests_data.append(
                {"id": str(i + 1), "method": "POST", "url": "/users", "body": user_data, "headers": {"Content-Type": "application/json"}}
            )

        batch_payload = {"requests": requests_data}

        try:
            # Wait if we're globally rate limited
            self._wait_for_rate_limit()
            
            # Log first user for debugging
            if requests_data:
                logger.debug(f"Sample user data: {requests_data[0]['body']['userPrincipalName']}")
            
            response = self.session.post(
                "https://graph.microsoft.com/v1.0/$batch",
                headers=self.get_headers(),
                json=batch_payload,
            )
            
            # Handle 401 - token expired
            if response.status_code == 401:
                logger.info("Got 401, refreshing access token...")
                self.access_token = None  # Force token refresh
                response = self.session.post(
                    "https://graph.microsoft.com/v1.0/$batch",
                    headers=self.get_headers(),
                    json=batch_payload,
                )
            
            if response.status_code != 200:
                # Log the full error response for debugging
                logger.error(f"Batch request failed with status {response.status_code}")
                try:
                    error_json = response.json()
                    logger.error(f"Error response: {error_json}")
                    # Check if it's a batch response with individual errors
                    if "responses" in error_json:
                        for resp in error_json["responses"][:3]:  # Log first 3 errors
                            if resp.get("status") != 201:
                                logger.error(f"Individual error: {resp}")
                except:
                    logger.error(f"Response text: {response.text[:1000]}")
            
            # Check if we got rate limited at the batch level
            if response.status_code == 429:
                self._handle_rate_limit_response(response)
                self._wait_for_rate_limit()
                # Retry the batch request after waiting
                response = self.session.post(
                    "https://graph.microsoft.com/v1.0/$batch",
                    headers=self.get_headers(),
                    json=batch_payload,
                )
            
            # Don't raise_for_status here - batch can return 200 with individual failures
            batch_response = response.json()
            created_users = []
            failed_count = 0
            throttled_count = 0

            for resp in batch_response.get("responses", []):
                if resp.get("status") == 201:
                    created_users.append(resp["body"])
                elif resp.get("status") == 429:
                    throttled_count += 1
                    failed_count += 1
                    # Check if individual response has Retry-After header
                    resp_headers = resp.get("headers", {})
                    retry_after = resp_headers.get("Retry-After")
                    if throttled_count == 1:  # Log once
                        if retry_after:
                            logger.warning(f"Individual requests throttled (429). Retry-After: {retry_after} seconds")
                        else:
                            error_msg = resp.get("body", {}).get("error", {}).get("message", "")
                            logger.warning(f"Individual requests throttled (429). Message: {error_msg}")
                else:
                    failed_count += 1
                    # Log first 3 non-throttle failures in detail
                    if failed_count <= 3 and resp.get("status") != 429:
                        logger.error(f"Failed to create user {resp.get('id')}: Status {resp.get('status')}")
                        if "body" in resp and "error" in resp["body"]:
                            logger.error(f"Error details: {resp['body']['error']}")
            
            # If all requests were throttled, we should wait and retry
            if throttled_count > 0 and created_users == 0:
                # Set global rate limit for individual 429s in batch
                # The message typically says "try after X seconds"
                self.rate_limit_until = time.time() + 150  # Default 150 seconds
                logger.info(f"All {throttled_count} requests in batch were throttled. Setting global rate limit for 150 seconds...")
                self._wait_for_rate_limit()
                return []  # Return empty to signal retry needed
            
            if failed_count > 3:
                logger.info(f"Total failures in batch: {failed_count} ({throttled_count} throttled)")
            
            return created_users

        except requests.exceptions.RequestException as e:
            logger.error(f"Batch user creation failed: {e}")
            return []

    def create_group(self, group_data: Dict) -> Optional[Dict]:
        """Create a single group"""
        try:
            # Wait if we're globally rate limited
            self._wait_for_rate_limit()
            
            response = self.session.post(
                "https://graph.microsoft.com/v1.0/groups",
                headers=self.get_headers(),
                json=group_data,
            )
            
            # Handle rate limiting
            if response.status_code == 429:
                self._handle_rate_limit_response(response)
                self._wait_for_rate_limit()
                response = self.session.post(
                    "https://graph.microsoft.com/v1.0/groups",
                    headers=self.get_headers(),
                    json=group_data,
                )
            
            # Handle 401 - token expired
            if response.status_code == 401:
                logger.info("Got 401, refreshing access token...")
                self.access_token = None  # Force token refresh
                response = self.session.post(
                    "https://graph.microsoft.com/v1.0/groups",
                    headers=self.get_headers(),
                    json=group_data,
                )
            
            response.raise_for_status()
            return response.json()

        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to create group {group_data.get('displayName')}: {e}")
            return None

    def create_all_users(self) -> List[Dict]:
        """Create all users with batch processing"""
        logger.info(f"Creating {self.generation_config.total_users} users...")

        all_created_users = []
        batch_size = self.generation_config.batch_size

        for i in range(0, self.generation_config.total_users, batch_size):
            batch_end = min(i + batch_size, self.generation_config.total_users)
            batch_user_data = []

            for j in range(i, batch_end):
                user_data = self.generate_fake_user_data(j + 1, self.cleanup_tag)
                batch_user_data.append(user_data)

            logger.info(
                f"Creating user batch {i // batch_size + 1}/{(self.generation_config.total_users + batch_size - 1) // batch_size}"
            )

            # Retry logic for throttled batches
            max_retries = 3
            for retry in range(max_retries):
                created_batch = self.create_users_batch(batch_user_data)
                if created_batch or retry == max_retries - 1:
                    # Either we got some users created or we've exhausted retries
                    all_created_users.extend(created_batch)
                    break
                else:
                    # Empty list means we were throttled and should retry
                    logger.info(f"Retrying batch {i // batch_size + 1} (attempt {retry + 2}/{max_retries})...")
                    continue

        logger.info(f"Successfully created {len(all_created_users)} users")
        self.created_users = all_created_users
        return all_created_users

    def create_group_hierarchy(self) -> List[Dict]:
        """Create groups with hierarchical structure, avoiding cycles"""
        logger.info(
            f"Creating {self.generation_config.total_groups} groups with hierarchy..."
        )

        all_created_groups = []
        groups_to_create = self.generation_config.total_groups

        # Create root-level groups first
        num_root_groups = max(1, int(groups_to_create * 0.3))  # 30% root groups

        logger.info(f"Creating {num_root_groups} root-level groups...")
        for i in range(num_root_groups):
            group_data = self.generate_fake_group_data(i + 1, None, self.cleanup_tag)
            created_group = self.create_group(group_data)

            if created_group:
                all_created_groups.append(created_group)
                self.group_hierarchy[created_group["id"]] = []

        # Create nested groups
        remaining_groups = groups_to_create - len(all_created_groups)
        current_group_index = len(all_created_groups)

        while remaining_groups > 0 and all_created_groups:
            # Select random parent groups that haven't reached max depth
            eligible_parents = [
                g
                for g in all_created_groups
                if self._get_group_depth(g["id"])
                < self.generation_config.max_hierarchy_depth
            ]

            if not eligible_parents:
                # Create more root groups if no eligible parents
                group_data = self.generate_fake_group_data(
                    current_group_index + 1, None, self.cleanup_tag
                )
                created_group = self.create_group(group_data)
                if created_group:
                    all_created_groups.append(created_group)
                    self.group_hierarchy[created_group["id"]] = []
                    current_group_index += 1
                    remaining_groups -= 1
                continue

            # Determine how many subgroups to create for each parent
            for parent_group in eligible_parents:
                if remaining_groups <= 0:
                    break

                # Use Poisson distribution for realistic subgroup counts
                num_subgroups = np.random.poisson(
                    self.generation_config.avg_subgroups_per_group
                )
                num_subgroups = min(
                    num_subgroups, remaining_groups, 5
                )  # Cap at 5 per parent

                for _ in range(num_subgroups):
                    if remaining_groups <= 0:
                        break

                    group_data = self.generate_fake_group_data(
                        current_group_index + 1,
                        parent_group["displayName"],
                        self.cleanup_tag,
                    )
                    created_group = self.create_group(group_data)

                    if created_group:
                        all_created_groups.append(created_group)
                        self.group_hierarchy[created_group["id"]] = []
                        self.group_hierarchy[parent_group["id"]].append(
                            created_group["id"]
                        )
                        current_group_index += 1
                        remaining_groups -= 1

        logger.info(f"Successfully created {len(all_created_groups)} groups")
        self.created_groups = all_created_groups
        return all_created_groups

    def _get_group_depth(
        self, group_id: str, visited: Optional[Set[str]] = None
    ) -> int:
        """Calculate the depth of a group in the hierarchy (cycle-safe)"""
        if visited is None:
            visited = set()

        if group_id in visited:
            return 0  # Cycle detected, return 0 depth

        visited.add(group_id)

        children = self.group_hierarchy.get(group_id, [])
        if not children:
            return 0

        max_child_depth = 0
        for child_id in children:
            child_depth = self._get_group_depth(child_id, visited.copy())
            max_child_depth = max(max_child_depth, child_depth)

        return max_child_depth + 1

    def assign_users_to_groups(self):
        """Assign users to groups based on average users per group"""
        if not self.created_users or not self.created_groups:
            logger.warning("No users or groups to assign")
            return

        logger.info("Assigning users to groups...")

        assignments_made = 0

        for group in self.created_groups:
            # Use Poisson distribution for realistic membership counts
            num_users = np.random.poisson(self.generation_config.avg_users_per_group)
            num_users = min(num_users, len(self.created_users))

            if num_users > 0:
                selected_users = random.sample(self.created_users, num_users)

                for user in selected_users:
                    success = self._add_user_to_group(user["id"], group["id"])
                    if success:
                        assignments_made += 1

        logger.info(f"Successfully created {assignments_made} group memberships")

    def _add_user_to_group(self, user_id: str, group_id: str) -> bool:
        """Add a user to a group"""
        try:
            # Wait if we're globally rate limited
            self._wait_for_rate_limit()
            
            payload = {"@odata.id": f"https://graph.microsoft.com/v1.0/users/{user_id}"}

            response = self.session.post(
                f"https://graph.microsoft.com/v1.0/groups/{group_id}/members/$ref",
                headers=self.get_headers(),
                json=payload,
            )
            
            # Handle rate limiting
            if response.status_code == 429:
                self._handle_rate_limit_response(response)
                self._wait_for_rate_limit()
                response = self.session.post(
                    f"https://graph.microsoft.com/v1.0/groups/{group_id}/members/$ref",
                    headers=self.get_headers(),
                    json=payload,
                )
            
            # Handle 401 - token expired
            if response.status_code == 401:
                logger.info("Got 401, refreshing access token...")
                self.access_token = None  # Force token refresh
                response = self.session.post(
                    f"https://graph.microsoft.com/v1.0/groups/{group_id}/members/$ref",
                    headers=self.get_headers(),
                    json=payload,
                )
            
            response.raise_for_status()
            return True

        except requests.exceptions.RequestException as e:
            if "already exists" in str(e).lower():
                return True  # User already in group, consider it success
            logger.warning(f"Failed to add user {user_id} to group {group_id}: {e}")
            return False

    def generate_all_test_data(self, skip_users=False, skip_groups=False, skip_memberships=False):
        """Main method to generate all test data
        
        Args:
            skip_users: Skip user creation
            skip_groups: Skip group creation
            skip_memberships: Skip membership assignment
        """
        if not self.generation_config:
            raise ValueError("Generation config required for data generation")

        logger.info("Starting test data generation...")
        logger.info(f"Cleanup tag: {self.cleanup_tag}")
        
        operations = []
        if not skip_users:
            operations.append(f"{self.generation_config.total_users} users")
        if not skip_groups:
            operations.append(f"{self.generation_config.total_groups} groups")
        if not skip_memberships:
            operations.append("group memberships")
            
        logger.info(f"Configuration: Creating {', '.join(operations)}")
        
        if skip_users:
            logger.info("Skipping user creation as requested")
        if skip_groups:
            logger.info("Skipping group creation as requested")
        if skip_memberships:
            logger.info("Skipping membership assignment as requested")

        try:
            # Get access token
            self.get_access_token()

            # Create users
            if not skip_users:
                self.create_all_users()
            else:
                # Try to find existing users with this tag for membership assignment
                if not skip_memberships:
                    logger.info(f"Looking for existing users with tag {self.cleanup_tag}...")
                    self.created_users = self.find_users_by_tag(self.cleanup_tag)
                    logger.info(f"Found {len(self.created_users)} existing users")

            # Create groups with hierarchy
            if not skip_groups:
                self.create_group_hierarchy()
            else:
                # Try to find existing groups with this tag for membership assignment
                if not skip_memberships:
                    logger.info(f"Looking for existing groups with tag {self.cleanup_tag}...")
                    self.created_groups = self.find_groups_by_tag(self.cleanup_tag)
                    logger.info(f"Found {len(self.created_groups)} existing groups")

            # Assign users to groups
            if not skip_memberships:
                self.assign_users_to_groups()

            logger.info("Test data generation completed successfully!")
            self._print_generation_summary()

        except Exception as e:
            logger.error(f"Test data generation failed: {e}")
            raise

    def _print_generation_summary(self):
        """Print summary of generated data"""
        print("\n" + "=" * 60)
        print("TEST DATA GENERATION SUMMARY")
        print("=" * 60)
        print(f"Cleanup tag: {self.cleanup_tag}")
        print(f"Users created: {len(self.created_users)}")
        print(f"Groups created: {len(self.created_groups)} (prefixed with 'TEST-{self.cleanup_tag}-')")
        print(
            f"Group hierarchy depth: {max([self._get_group_depth(g['id']) for g in self.created_groups], default=0)}"
        )
        print(
            f"Root groups: {len([g for g in self.created_groups if not any(g['id'] in children for children in self.group_hierarchy.values())])}"
        )
        print("\nTo clean up this data later, use:")
        print(
            f"python {sys.argv[0]} --cleanup-tag '{self.cleanup_tag}' --tenant-id {self.entra_config.tenant_id} --client-id {self.entra_config.client_id} --client-secret ****"
        )
        print("=" * 60)

    # ============================================================================
    # CLEANUP METHODS
    # ============================================================================

    def find_users_by_tag(self, cleanup_tag: str) -> List[Dict]:
        """Find all users with the specified cleanup tag"""
        logger.info(f"Searching for users with cleanup tag: {cleanup_tag}")

        all_tagged_users = []

        try:
            # Search users by employeeId (where we store the cleanup tag)
            filter_query = f"employeeId eq '{cleanup_tag}'"
            url = f"https://graph.microsoft.com/v1.0/users?$filter={urllib.parse.quote(filter_query)}&$select=id,displayName,userPrincipalName,employeeId"

            response = self.session.get(url, headers=self.get_headers())
            response.raise_for_status()

            data = response.json()
            users = data.get("value", [])

            logger.info(f"Found {len(users)} users with cleanup tag '{cleanup_tag}'")
            all_tagged_users.extend(users)

            # Handle pagination
            while "@odata.nextLink" in data:
                response = self.session.get(
                    data["@odata.nextLink"], headers=self.get_headers()
                )
                response.raise_for_status()
                data = response.json()
                users = data.get("value", [])
                all_tagged_users.extend(users)

            # No need for backup search with the new tagging approach

        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to search users with tag '{cleanup_tag}': {e}")
            return []

        logger.info(f"Found {len(all_tagged_users)} total users with cleanup tag")
        return all_tagged_users

    def find_groups_by_tag(self, cleanup_tag: str) -> List[Dict]:
        """Find all groups with the specified cleanup tag in displayName"""
        logger.info(f"Searching for groups with cleanup tag: {cleanup_tag}")

        all_tagged_groups = []

        try:
            # Search groups by displayName prefix (much more reliable than description)
            filter_query = f"startswith(displayName, 'TEST-{cleanup_tag}-')"
            url = f"https://graph.microsoft.com/v1.0/groups?$filter={urllib.parse.quote(filter_query)}&$select=id,displayName,description,mailNickname"

            response = self.session.get(url, headers=self.get_headers())
            response.raise_for_status()

            data = response.json()
            groups = data.get("value", [])
            all_tagged_groups.extend(groups)

            logger.info(
                f"Found {len(groups)} groups with cleanup tag '{cleanup_tag}' in first batch"
            )

            # Handle pagination
            while "@odata.nextLink" in data:
                response = self.session.get(
                    data["@odata.nextLink"], headers=self.get_headers()
                )
                response.raise_for_status()
                data = response.json()
                groups = data.get("value", [])
                all_tagged_groups.extend(groups)

        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to search groups with tag '{cleanup_tag}': {e}")
            return []

        logger.info(f"Found {len(all_tagged_groups)} total groups with cleanup tag")
        return all_tagged_groups

    def list_all_cleanup_tags(self) -> List[str]:
        """List all available cleanup tags in the tenant"""
        logger.info("Searching for all cleanup tags...")

        cleanup_tags = set()

        try:
            # Search for users with employeeId starting with "LT" (our tag prefix)
            filter_query = "startswith(employeeId, 'LT')"
            url = f"https://graph.microsoft.com/v1.0/users?$filter={urllib.parse.quote(filter_query)}&$select=employeeId"

            response = self.session.get(url, headers=self.get_headers())
            response.raise_for_status()

            data = response.json()

            for user in data.get("value", []):
                if user.get("employeeId"):
                    cleanup_tags.add(user["employeeId"])

            # Handle pagination
            while "@odata.nextLink" in data:
                response = self.session.get(
                    data["@odata.nextLink"], headers=self.get_headers()
                )
                response.raise_for_status()
                data = response.json()
                for user in data.get("value", []):
                    if user.get("employeeId"):
                        cleanup_tags.add(user["employeeId"])

            # Also search groups for cleanup tags using displayName prefix
            filter_query = "startswith(displayName, 'TEST-LT')"
            url = f"https://graph.microsoft.com/v1.0/groups?$filter={urllib.parse.quote(filter_query)}&$select=displayName"

            response = self.session.get(url, headers=self.get_headers())
            response.raise_for_status()

            data = response.json()

            for group in data.get("value", []):
                display_name = group.get("displayName", "")
                if display_name.startswith("TEST-LT"):
                    # Extract the tag from displayName (format: TEST-{tag}-{rest})
                    # Tag format is now: LT + 8 digits + 4 digits
                    parts = display_name.split("-", 2)  # TEST-LT##########-rest
                    if len(parts) >= 2 and parts[1].startswith("LT"):
                        tag = parts[1]  # The full LT########## tag
                        cleanup_tags.add(tag)

            # Handle pagination for groups
            while "@odata.nextLink" in data:
                response = self.session.get(
                    data["@odata.nextLink"], headers=self.get_headers()
                )
                response.raise_for_status()
                data = response.json()
                for group in data.get("value", []):
                    display_name = group.get("displayName", "")
                    if display_name.startswith("TEST-LT"):
                        parts = display_name.split("-", 2)
                        if len(parts) >= 2 and parts[1].startswith("LT"):
                            tag = parts[1]
                            cleanup_tags.add(tag)

        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to search for cleanup tags: {e}")

        return sorted(list(cleanup_tags))

    def delete_users(self, users: List[Dict], confirm: bool = False) -> int:
        """Delete specified users"""
        if not users:
            logger.info("No users to delete")
            return 0

        if not confirm:
            logger.warning(f"DRY RUN: Would delete {len(users)} users")
            for user in users[:10]:  # Show first 10
                logger.info(
                    f"  - {user['displayName']} ({user.get('userPrincipalName', 'N/A')})"
                )
            if len(users) > 10:
                logger.info(f"  ... and {len(users) - 10} more")
            return 0

        logger.info(f"Deleting {len(users)} users...")
        deleted_count = 0

        for i, user in enumerate(users, 1):
            try:
                response = self.session.delete(
                    f"https://graph.microsoft.com/v1.0/users/{user['id']}",
                    headers=self.get_headers(),
                )
                response.raise_for_status()

                logger.info(f"Deleted user {i}/{len(users)}: {user['displayName']}")
                deleted_count += 1

            except requests.exceptions.RequestException as e:
                logger.error(f"Failed to delete user {user['displayName']}: {e}")

        logger.info(f"Successfully deleted {deleted_count} users")
        return deleted_count

    def delete_groups(self, groups: List[Dict], confirm: bool = False) -> int:
        """Delete specified groups"""
        if not groups:
            logger.info("No groups to delete")
            return 0

        if not confirm:
            logger.warning(f"DRY RUN: Would delete {len(groups)} groups")
            for group in groups[:10]:  # Show first 10
                logger.info(f"  - {group['displayName']}")
            if len(groups) > 10:
                logger.info(f"  ... and {len(groups) - 10} more")
            return 0

        logger.info(f"Deleting {len(groups)} groups...")
        deleted_count = 0

        for i, group in enumerate(groups, 1):
            try:
                response = self.session.delete(
                    f"https://graph.microsoft.com/v1.0/groups/{group['id']}",
                    headers=self.get_headers(),
                )
                response.raise_for_status()

                logger.info(f"Deleted group {i}/{len(groups)}: {group['displayName']}")
                deleted_count += 1

            except requests.exceptions.RequestException as e:
                logger.error(f"Failed to delete group {group['displayName']}: {e}")

        logger.info(f"Successfully deleted {deleted_count} groups")
        return deleted_count

    def cleanup_by_tag(
        self,
        cleanup_tag: str,
        confirm: bool = False,
        users_only: bool = False,
        groups_only: bool = False,
    ):
        """Find and clean up all test data with the specified tag"""
        logger.info(f"Starting cleanup for tag: {cleanup_tag}")

        # Find tagged entities
        tagged_users = [] if groups_only else self.find_users_by_tag(cleanup_tag)
        tagged_groups = [] if users_only else self.find_groups_by_tag(cleanup_tag)

        if not tagged_users and not tagged_groups:
            logger.info(f"No entities found with cleanup tag: {cleanup_tag}")
            return

        # Show summary
        print("\n" + "=" * 60)
        print(f"CLEANUP SUMMARY FOR TAG: {cleanup_tag}")
        print("=" * 60)
        if not groups_only:
            print(f"Tagged users found: {len(tagged_users)}")
        if not users_only:
            print(f"Tagged groups found: {len(tagged_groups)}")
        print("=" * 60)

        if not confirm:
            print("This is a DRY RUN. Use --confirm to actually delete.")
            print("=" * 60)

        # Delete users first (to avoid membership issues)
        deleted_users = (
            self.delete_users(tagged_users, confirm) if not groups_only else 0
        )

        # Then delete groups
        deleted_groups = (
            self.delete_groups(tagged_groups, confirm) if not users_only else 0
        )

        if confirm:
            print(f"\nCleanup completed for tag '{cleanup_tag}':")
            if not groups_only:
                print(f"  Users deleted: {deleted_users}")
            if not users_only:
                print(f"  Groups deleted: {deleted_groups}")
        else:
            print(f"\nDry run completed for tag '{cleanup_tag}'. Would delete:")
            if not groups_only:
                print(f"  Users: {len(tagged_users)}")
            if not users_only:
                print(f"  Groups: {len(tagged_groups)}")


def main():
    parser = argparse.ArgumentParser(description="Microsoft Entra ID Test Data Manager")
    parser.add_argument("--tenant-id", required=True, help="Azure AD Tenant ID")
    parser.add_argument("--client-id", required=True, help="Application Client ID")
    parser.add_argument(
        "--client-secret", required=True, help="Application Client Secret"
    )

    # Mode selection
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument("--cleanup-tag", help="Clean up data with specific tag")
    mode_group.add_argument(
        "--list-tags", action="store_true", help="List all available cleanup tags"
    )

    # Generation parameters (only used when not in cleanup mode)
    parser.add_argument(
        "--tenant-domain",
        help="Tenant domain (e.g., contoso.onmicrosoft.com) - required for generation",
    )
    parser.add_argument(
        "--total-groups", type=int, default=100, help="Total number of groups to create"
    )
    parser.add_argument(
        "--total-users", type=int, default=1000, help="Total number of users to create"
    )
    
    # Options to skip certain operations
    parser.add_argument(
        "--skip-users", action="store_true", help="Skip user creation"
    )
    parser.add_argument(
        "--skip-groups", action="store_true", help="Skip group creation"
    )
    parser.add_argument(
        "--skip-memberships", action="store_true", help="Skip membership assignment"
    )
    parser.add_argument(
        "--use-existing-tag", help="Use an existing cleanup tag to find users/groups for membership assignment"
    )
    parser.add_argument(
        "--avg-subgroups-per-group",
        type=float,
        default=2.0,
        help="Average subgroups per group",
    )
    parser.add_argument(
        "--avg-users-per-group",
        type=float,
        default=10.0,
        help="Average users per group",
    )
    parser.add_argument(
        "--max-depth", type=int, default=5, help="Maximum hierarchy depth"
    )
    parser.add_argument(
        "--batch-size", type=int, default=20, help="Batch size for API calls"
    )
    parser.add_argument(
        "--max-retries",
        type=int,
        default=5,
        help="Maximum number of retries for rate-limited requests",
    )

    # Cleanup options
    parser.add_argument(
        "--confirm",
        action="store_true",
        help="Actually delete (without this, cleanup is a dry run)",
    )
    parser.add_argument("--users-only", action="store_true", help="Only clean up users")
    parser.add_argument(
        "--groups-only", action="store_true", help="Only clean up groups"
    )

    args = parser.parse_args()

    # Determine mode
    if args.list_tags or args.cleanup_tag:
        # Cleanup mode
        entra_config = EntraConfig(
            tenant_id=args.tenant_id,
            client_id=args.client_id,
            client_secret=args.client_secret,
        )
        manager = EntraTestManager(entra_config)

        try:
            manager.get_access_token()

            if args.list_tags:
                tags = manager.list_all_cleanup_tags()
                if tags:
                    print("Available cleanup tags:")
                    for tag in tags:
                        users = manager.find_users_by_tag(tag)
                        groups = manager.find_groups_by_tag(tag)
                        print(f"  {tag}: {len(users)} users, {len(groups)} groups")
                else:
                    print("No cleanup tags found")
            else:
                manager.cleanup_by_tag(
                    args.cleanup_tag, args.confirm, args.users_only, args.groups_only
                )

        except Exception as e:
            logger.error(f"Cleanup failed: {e}")
            sys.exit(1)

    else:
        # Generation mode
        if not args.tenant_domain and not args.skip_users:
            parser.error("--tenant-domain is required for user generation")

        entra_config = EntraConfig(
            tenant_id=args.tenant_id,
            client_id=args.client_id,
            client_secret=args.client_secret,
            tenant_domain=args.tenant_domain,
        )

        generation_config = GenerationConfig(
            total_groups=args.total_groups,
            total_users=args.total_users,
            avg_subgroups_per_group=args.avg_subgroups_per_group,
            avg_users_per_group=args.avg_users_per_group,
            max_hierarchy_depth=args.max_depth,
            batch_size=args.batch_size,
            max_retries=args.max_retries,
        )

        manager = EntraTestManager(entra_config, generation_config)
        
        # Override cleanup tag if using existing one
        if args.use_existing_tag:
            manager.cleanup_tag = args.use_existing_tag
            logger.info(f"Using existing cleanup tag: {manager.cleanup_tag}")

        try:
            manager.generate_all_test_data(
                skip_users=args.skip_users,
                skip_groups=args.skip_groups,
                skip_memberships=args.skip_memberships
            )
        except Exception as e:
            logger.error(f"Generation failed: {e}")
            sys.exit(1)


if __name__ == "__main__":
    main()
