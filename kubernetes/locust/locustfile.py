"""
locustfile.py — Black Friday traffic simulation for Google Online Boutique.
Simulates realistic e-commerce user journeys: browse → view product → add to cart → checkout.
Used for both Phase 9 runs:
  Run 1: HPA reactive baseline
  Run 2: KEDA + Holt-Winters predictive
"""

from locust import HttpUser, task, between
import random

# Product IDs from Google Online Boutique catalog
PRODUCT_IDS = [
    "0PUK6V6EV0",
    "1YMWWN1N4O",
    "2ZYFJ3GM2N",
    "66VCHSJNUP",
    "6E92ZMYYFZ",
    "9SIQT8TOJO",
    "L9ECAV4FNI",
    "LS4PSXUNUM",
    "OLJCESPC7Z",
]

class OnlineBoutiqueUser(HttpUser):
    # wait_between: simulated think time between user actions (0.5–2 seconds)
    wait_time = between(0.5, 2)

    @task(5)
    def browse_homepage(self):
        """Most common action — user lands on homepage. Weight 5 = 5x more frequent."""
        self.client.get("/", name="Homepage")

    @task(3)
    def view_product(self):
        """User browses a product page. Weight 3."""
        product_id = random.choice(PRODUCT_IDS)
        self.client.get(f"/product/{product_id}", name="Product Page")

    @task(2)
    def add_to_cart(self):
        """User adds item to cart. Weight 2."""
        product_id = random.choice(PRODUCT_IDS)
        self.client.post("/cart", data={
            "product_id": product_id,
            "quantity": random.randint(1, 3)
        }, name="Add to Cart")

    @task(1)
    def view_cart(self):
        """User views cart. Weight 1 = least frequent."""
        self.client.get("/cart", name="View Cart")
